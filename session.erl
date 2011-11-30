-module(session).
-export([start/3]).

-include("protocol.hrl").

-record(transaction, {current, buckets}).
-record(state, {buckets, monitor, transaction=none, watches=none}).

start(shell, BucketMap, MonitorMap) ->
    io:format("starting shell session with pid ~p~n", [self()]),
    loop(shell, #state{buckets=BucketMap, monitor=MonitorMap});
start(Client, BucketMap, MonitorMap) ->
    {ok, {Addr, Port}} = inet:peername(Client),
    io:format("starting client session with pid ~p and remote connection ~p:~p~n", [self(), inet_parse:ntoa(Addr), Port]),
    loop(Client, #state{buckets=BucketMap, monitor=MonitorMap}),
    gen_tcp:close(Client).

loop(Client, State) ->
    receive
        {tcp, Client, Data} ->
            io:format("session received tcp message ~p~n", [Data]),
            loop(Client, State);
        {tcp_closed, Client} ->
            io:format("session connection closed~n");
        {From, watch, Key} ->
            loop(Client, handle_watch(State, From, Key));
        {From, unwatch} ->
            loop(Client, handle_unwatch(State, From));
        {From, multi} ->
            loop(Client, handle_multi(State, From));
        {From, exec} ->
            loop(Client, handle_exec(State, From));
        {From, Key, Operation} ->
            loop(Client, handle_operation(State, From, Key, Operation));
        stop ->
            io:format("dtm-redis shell halting after receiving stop message~n");
        Any ->
            io:format("session received message ~p~n", [Any]),
            loop(Client, State)
    end.

handle_watch(State, From, Key) ->
    Bucket = hash:worker_for_key(Key, State#state.buckets),
    Bucket ! #watch{session=self(), key=Key},
    From ! receive
        {Bucket, ok} -> {self(), ok}
    end,
    State#state{watches=add_watch(State#state.watches, Bucket)}.

add_watch(none, Bucket) ->
    sets:add_element(Bucket, sets:new());
add_watch(Watches, Bucket) ->
    sets:add_element(Bucket, Watches).

handle_unwatch(State, From) ->
    From ! {self(), send_unwatch(State#state.watches)},
    State#state{watches=none}.

send_unwatch(none) ->
    ok;
send_unwatch(Watches) ->
    sets:fold(fun(Bucket, NotUsed) -> Bucket ! #unwatch{session=self()}, NotUsed end, not_used, Watches),
    loop_unwatch(Watches, sets:size(Watches)).

loop_unwatch(_, 0) ->
    ok;
loop_unwatch(Watches, _) ->
    receive
        {Bucket, ok} ->
            NewWatches = sets:del_element(Bucket, Watches),
            loop_unwatch(NewWatches, sets:size(NewWatches))
    end.

handle_multi(State, From) ->
    case State#state.transaction of
        none ->
            From ! {self(), ok},
            State#state{transaction=#transaction{current=0, buckets=sets:new()}};
        #transaction{} ->
            From ! {self(), error},
            State
    end.

handle_exec(State, From) ->
    case State#state.transaction of
        none ->
            From ! {self(), error},
            State;
        #transaction{buckets=Buckets} ->
            From ! {self(), commit_transaction(Buckets)},
            State#state{transaction=none}
    end.

handle_operation(#state{transaction=none}=State, From, Key, Operation) ->
    Bucket = hash:worker_for_key(Key, State#state.buckets),
    Bucket ! #command{session=self(), operation=Operation},
    receive
        {Bucket, Response} -> From ! {self(), Response};
        Any -> io:format("session got an unexpected message ~p~n", [Any])
    end,
    State;
handle_operation(#state{transaction=Transaction}=State, From, Key, Operation) ->
    Bucket = hash:worker_for_key(Key, State#state.buckets),
    Bucket ! #transact{session=self(), id=Transaction#transaction.current, operation=Operation},
    receive
        {Bucket, Response} -> From ! {self(), Response};
        Any -> io:format("session got an unexpected message ~p~n", [Any])
    end,
    Current = Transaction#transaction.current + 1,
    Buckets = sets:add_element(Bucket, Transaction#transaction.buckets),
    NewTransaction = Transaction#transaction{current=Current, buckets=Buckets},
    State#state{transaction=NewTransaction}.

commit_transaction(Buckets) ->
    sets:fold(fun(Bucket, NotUsed) -> Bucket ! #lock_transaction{session=self()}, NotUsed end, not_used, Buckets),
    case loop_transaction_lock(Buckets, sets:size(Buckets), false) of
        error ->
            sets:fold(fun(Bucket, NotUsed) -> Bucket ! #rollback_transaction{session=self()}, NotUsed end, not_used, Buckets),
            error;
        ok ->
            sets:fold(fun(Bucket, NotUsed) -> Bucket ! #commit_transaction{session=self(), now=erlang:now()}, NotUsed end, not_used, Buckets),
            {ok, loop_transaction_commit(Buckets, [], sets:size(Buckets))}
    end.

loop_transaction_lock(_Buckets, 0, false) ->
    ok;
loop_transaction_lock(_Buckets, 0, true) ->
    error;
loop_transaction_lock(Buckets, _Size, Failure) ->
    receive
        #transaction_locked{bucket=Bucket, status=Status} ->
            NewBuckets = sets:del_element(Bucket, Buckets),
            loop_transaction_lock(NewBuckets, sets:size(NewBuckets), Failure or (Status =:= error));
        Any ->
            io:format("session got an unexpected message ~p~n", [Any])
    end.

loop_transaction_commit(_Buckets, Results, 0) ->
    [Result || {_, Result} <- lists:sort(fun({Lhs, _}, {Rhs, _}) -> Lhs =< Rhs end, lists:flatten(Results))];
loop_transaction_commit(Buckets, ResultsSoFar, _) ->
    receive
        {Bucket, Results} ->
            NewBuckets = sets:del_element(Bucket, Buckets),
            NewResultsSoFar = [Results|ResultsSoFar],
            loop_transaction_commit(NewBuckets, NewResultsSoFar, sets:size(NewBuckets));
        Any ->
            io:format("session got an unexpected message ~p~n", [Any])
    end.