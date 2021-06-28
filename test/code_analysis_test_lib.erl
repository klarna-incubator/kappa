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
-module(code_analysis_test_lib).

-export([erlang_code_to_abst/1]).

erlang_code_to_abst(ErlangCode) ->
  erlang_code_to_abst(ErlangCode, 1, []).

erlang_code_to_abst([], _Line, Acc) ->
  lists:reverse(Acc);
erlang_code_to_abst(String, Line, Acc) ->
  {done, {ok, Tokens, NewLine}, Rest} = erl_scan:tokens([], String, Line),
  {ok, Abst} = erl_parse:parse_form(Tokens),
  erlang_code_to_abst(Rest, NewLine, [Abst | Acc]).
