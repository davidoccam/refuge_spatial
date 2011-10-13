%%% -*- erlang -*-
%%%
%%% This file is part of geocouch released under the Apache license 2. 
%%% See the NOTICE for more information.


-module(vtree_insbench).
-export([start/0]).

-export([test_insertion/0, profile_insertion/0]).

-define(FILENAME, "/tmp/vtree_huge.bin").

-record(node, {
    % type = inner | leaf
    type=leaf}).

start() ->
    %test_insertion(),
    %profile_insertion(),
    etap:end_tests().

test_insertion() ->
    etap:plan(1),

    case couch_file:open(?FILENAME, [create, overwrite]) of
    {ok, Fd} ->
        Max = 1000,
        Tree = lists:foldl(
            fun(Count, CurTreePos) ->
                RandomMbr = {random:uniform(Max), random:uniform(Max),
                             random:uniform(Max), random:uniform(Max)},
                %io:format("~p~n", [RandomMbr]),
                {ok, _, NewRootPos} = vtree:insert(
                    Fd, CurTreePos,
                    {RandomMbr, #node{type=leaf},
                     list_to_binary("Node" ++ integer_to_list(Count))}),
                %io:format("test_insertion: ~p~n", [NewRootPos]),
                NewRootPos
            end, -1, lists:seq(1,5000)),
            %end, -1, lists:seq(1,60000)),
        io:format("Tree: ~p~n", [Tree]),
        ok;
    {error, _Reason} ->
        io:format("ERROR: Couldn't open file (~s) for tree storage~n",
                  [?FILENAME])
    end.

profile_insertion() ->
     fprof:apply(insertion, test_insertion, []),
     fprof:profile(),
     fprof:analyse().
