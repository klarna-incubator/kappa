%%%
%%%   Copyright (c) 2021 Klarna Bank AB (publ)
%%%
%%%   Licensed under the Apache License, Version 2.0 (the "License");
%%%   you may not use this file except in compliance with the License.
%%%   You may obtain a copy of the License at
%%%
%%%       http://www.apache.org/licenses/LICENSE-2.0
%%%
%%%   Unless required by applicable law or agreed to in writing, software
%%%   distributed under the License is distributed on an "AS IS" BASIS,
%%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%%   See the License for the specific language governing permissions and
%%%   limitations under the License.
%%%
-module(graphviz).

-export([ to_dot/2
        , to_dot/3
        , to_dot/4
        , to_dot/5
        , run_dot/3
        ]).

%%%=============================================================================
%%%
%%% Dot interface.
%%%
%%% Typical workflow:
%%%   1. Create dot string using to_dot/2-5, e.g.:
%%%        graphviz:to_dot("G",                         % graph name
%%%                        [{a, b}, {b, c}, {a, c}],    % edge list
%%%                        [{a, [{style, filled}]}],    % named-node options
%%%                        [{rankdir, "LR"}],           % graph options
%%%                        [{node, [ {shape, box}       % general options
%%%                                , {style, rounded}]}]).
%%%   2. Make modifications to the string if you know what you are doing.
%%%   3. Run dot to make your final output (gif, ps, etc.) using run_dot/3.
%%%   4. ...
%%%   5. Profit
%%%
%%% Preferably, use atoms, strings or integers as nodenames. It can
%%% work for nasty characters (e.g., tuples, records), but don't bet
%%% your life on it.
%%%

run_dot(Dotfile, OutFile, Type) ->
  String = io_lib:format("dot ~s -o ~s ~s",
                         [format_dot_type(Type), OutFile, Dotfile]),
  case os:cmd(String) of
    "" -> ok;
    Error -> erlang:error(Error)
  end.

format_dot_type(gif) -> "-Tgif";
format_dot_type(pdf) -> "-Tpdf";
format_dot_type(png) -> "-Tpng";
format_dot_type(ps)  -> "-Tps";
format_dot_type(svg) -> "-Tsvg".

-type dot_attr() :: {Name :: atom(), Val :: any()}.

-type dot_edge() :: ({From :: any(), To :: any()}
                     | {From :: any(), To :: any(), [dot_attr()]}).

-type dot_node_opts() :: {Name :: _, [dot_attr()]}.

-type dot_graph_opt() :: {OptName :: atom(), OptVal :: any()}.

-spec to_dot(string(), [dot_edge()]) -> string().

to_dot(GraphName, EdgeList) ->
  to_dot(GraphName, EdgeList, []).

-spec to_dot(string(), [dot_edge()], [dot_node_opts()]) -> string().

to_dot(GraphName, EdgeList, NodeOpts) ->
  to_dot(GraphName, EdgeList, NodeOpts, []).

-spec to_dot(string(), [dot_edge()], [dot_node_opts()], [dot_graph_opt()]) ->
  string().

to_dot(GraphName, EdgeList, NodeOpts, GraphOpts) ->
  to_dot(GraphName, EdgeList, NodeOpts, GraphOpts, []).

-spec to_dot(GraphName     :: string(),
             EdgeList      :: [dot_edge()],
             NodeOpts      :: [dot_node_opts()],
             GraphOpts     :: [dot_graph_opt()],
             GenOpts       :: [dot_node_opts()])
            -> string().

to_dot(GraphName, EdgeList, NodeOpts, GraphOpts, GenOpts) ->
  S0 = [format_dot_graph_opt(O) || O <- GraphOpts],
  S1 = [format_dot_gen_opt(O) || O <- GenOpts],
  S2 = [format_dot_node(N) || N <- NodeOpts],
  S3 = [format_dot_edge(E) || E <- EdgeList],
  S4 = io_lib:format("digraph ~p {\n~s~s~s~s}\n",
                     [to_string(GraphName), S0, S1, S2, S3]),
  lists:flatten(S4).

format_dot_edge({From, To}) ->
  io_lib:format("~p -> ~p\n", [to_string(From), to_string(To)]);
format_dot_edge({From, To, Attrs}) ->
  io_lib:format("~p -> ~p [~s]\n",
                [to_string(From), to_string(To), format_dot_attrs(Attrs)]).

format_dot_node({Node, Attrs}) ->
  io_lib:format("~p [~s]\n", [to_string(Node), format_dot_attrs(Attrs)]).

format_dot_attrs(List) ->
  lists:map(fun format_dot_attr/1, List).

format_dot_attr({Name, Val}) ->
  io_lib:format("~p=~p", [to_string(Name), to_string(Val)]).

format_dot_graph_opt({same_rank, List}) ->
  Nodes = string:join([io_lib:format("~p", [to_string(Node)]) || Node <- List],
                      " "),
  io_lib:format("{rank=same; ~s}\n", [Nodes]);
format_dot_graph_opt({Opt, Val}) ->
  io_lib:format("graph[~s=~s];\n", [to_string(Opt), to_string(Val)]).

format_dot_gen_opt({Opt, List}) ->
  Attrs = string:join([format_dot_gen_attr(A) || A <- List], ","),
  io_lib:format("~s[~s];\n", [atom_to_list(Opt), Attrs]).

format_dot_gen_attr({K, V}) ->
  io_lib:format("~p=~p", [K, V]).

to_string(What) ->
  [X || X <- lists:flatten(io_lib:format("~p", [What])), X =/= $\"].

%%% Local Variables:
%%% erlang-indent-level: 2
%%% End:
