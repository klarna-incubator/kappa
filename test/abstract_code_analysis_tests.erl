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
-module(abstract_code_analysis_tests).

-include_lib("eunit/include/eunit.hrl").

get_module_test_() ->
  [
   ?_assertEqual(
       1
     , length([L || {attribute, L, module, ?MODULE} <-
                        abstract_code_analysis:get_module_abstract(?MODULE)])
     )
  ].

function_from_abstract_test_() ->
  [
   ?_assertEqual(
      {function, 2, f, 0, [{clause, 2, [], [], [{atom, 2, atom}]}]},
      abstract_code_analysis:function_from_abstract(
        code_analysis_test_lib:erlang_code_to_abst(
          "-module(test).\n"
          "f() -> atom.\n"),
        {test, f, 0})),
   ?_assertEqual(
      {function, 2, f, 0, [{clause, 2, [], [], [{atom, 2, atom}]}]},
      abstract_code_analysis:function_from_abstract(
        code_analysis_test_lib:erlang_code_to_abst(
          "-module(test).\n"
          "f() -> atom.\n"
          "g() -> atom.\n"),
        {test, f, 0})),
   ?_assertException(
      error, _,
      abstract_code_analysis:function_from_abstract(
        code_analysis_test_lib:erlang_code_to_abst(
          "-module(test).\n"
          "g() -> atom.\n"),
        {test, f, 0})),
   ?_assertException(
      error, _,
      abstract_code_analysis:function_from_abstract(
        code_analysis_test_lib:erlang_code_to_abst(
          "-module(test).\n"
          "f() -> atom.\n"
          "f() -> atom.\n"),
        {test, f, 0}))
  ].

local_call_test_() ->
  [
   ?_assert(
      abstract_code_analysis:local_call_possible(
        {test, f, 0},
        code_analysis_test_lib:erlang_code_to_abst(
          "-module(test).\n"
          "f() -> atom.\n"))),
   ?_assertNot(
      abstract_code_analysis:local_call_possible(
        {test, f, 0},
        code_analysis_test_lib:erlang_code_to_abst(
          "-module(test2).\n"
          "f() -> atom.\n"))),
   ?_assert(
      abstract_code_analysis:local_call_possible(
        {test, f, 0},
        code_analysis_test_lib:erlang_code_to_abst(
          "-module(test2).\n"
          "-import(test, [f/0]).\n"
          "f() -> atom.\n"))),
   ?_assertNot(
      abstract_code_analysis:local_call_possible(
        {test, f, 0},
        code_analysis_test_lib:erlang_code_to_abst(
          "-module(test2).\n"
          "-import(test, [g/0]).\n"
          "f() -> atom.\n"))),
   ?_assertNot(
      abstract_code_analysis:local_call_possible(
        {test, f, 0},
        code_analysis_test_lib:erlang_code_to_abst(
          "-module(test2).\n"
          "-import(test, [f/1]).\n"
          "f() -> atom.\n"))),
   ?_assertNot(
      abstract_code_analysis:local_call_possible(
        {test, f, 0},
        code_analysis_test_lib:erlang_code_to_abst(
          "-module(test2).\n"
          "-import(test3, [f/0]).\n"
          "f() -> atom.\n")))
  ].

scan_for_calls_test_() ->
  [
   ?_assertEqual(
      [],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> g().\n"),
        {test, f, 0},
        false)),
   ?_assertEqual(
      [],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> g().\n"),
        {test, g, 0},
        false)),
   ?_assertEqual(
      [[]],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> test:g().\n"),
        {test, g, 0},
        false)),
   ?_assertEqual(
      [[]],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> g().\n"),
        {test, g, 0},
        true)),
   ?_assertEqual(
      [],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> g().\n"),
        {test, h, 0},
        true)),
   ?_assertEqual(
      ['fun'],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> fun test:g/0.\n"),
        {test, g, 0},
        false)),
   ?_assertEqual(
      [],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> fun g/0.\n"),
        {test, g, 0},
        false)),
   ?_assertEqual(
      ['fun'],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> fun g/0.\n"),
        {test, g, 0},
        true))
  ].

scan_for_calls_parameters_test_() ->
  [
   ?_assertEqual(
      [[{atom, 1, atom}]],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> g(atom).\n"),
        {test, g, 1},
        true)),
   ?_assertEqual(
      [[{atom, 1, atom}], [{atom, 1, other_atom}]],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> g(atom), g(other_atom).\n"),
        {test, g, 1},
        true)),
   ?_assertEqual(
      [[{atom, 1, atom}, {atom, 1, other_atom}]],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> g(atom, other_atom).\n"),
        {test, g, 2},
        true)),
   ?_assertEqual(
      [[{var, 1, 'Var'}]],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f(Var) -> g(Var).\n"),
        {test, g, 1},
        true)),
   ?_assertEqual(
      [[{call, 1, {atom, 1, h}, []}]],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> g(h()).\n"),
        {test, g, 1},
        true)),
   ?_assertEqual(
      [[{call, 1, {remote, 1, {atom, 1, test},{atom, 1, h}}, []}]],
      abstract_code_analysis:scan_for_calls(
        code_analysis_test_lib:erlang_code_to_abst(
          "f(Var) -> g(test:h()).\n"),
        {test, g, 1},
        true))
  ].

scan_for_record_field_test_() ->
  [
   ?_assertEqual(
      [],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> #test{}.\n"))),
   ?_assertEqual(
      [{test, field, 1, set}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> #test{field = field}.\n"))),
   ?_assertEqual(
      [{test, other_field, 1, set}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> #test{other_field = field}.\n"))),
   ?_assertEqual(
      [{test, field, 1, set},
       {test, other_field, 2, set}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> #test{field = field,\n"
          "other_field = field}.\n"))),
   ?_assertEqual(
      [{test, other_field, 1, set},
       {test, field, 2, set}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> #test{other_field = field,\n"
          "field = field}.\n"))),
   ?_assertEqual(
      [{other_rec, field, 1, set}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> #other_rec{field = field}.\n"))),
   ?_assertEqual(
      [{test, field, 1, set}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f(V) -> V#test{field = field}.\n"))),
   ?_assertEqual(
      [{test, field, 1, get}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f(V) -> V#test.field.\n"))),
   ?_assertEqual(
      [{test, field, 1, index}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f() -> #test.field.\n"))),
   ?_assertEqual(
      [{test, field, 1, index},
       {test, field, 2, get}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f(V) -> #test.field,\n"
          "V#test.field.\n"))),
   ?_assertEqual(
      [{test, field, 1, index},
       {test, field, 1, get}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f(V) -> #test.field, V#test.field.\n"))),
   ?_assertEqual(
      [{test, field, 1, get}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f(V) -> #test{field = Field} = V.\n"))),
   ?_assertEqual(
      [{test, field, 1, get}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f(#test{field = Field}) -> Field.\n"))),
   ?_assertEqual(
      [{test, field, 1, get}],
      abstract_code_analysis:scan_for_record_fields(
        code_analysis_test_lib:erlang_code_to_abst(
          "f(L) -> [Field || #test{field = Field} <- L].\n")))
  ].



%%% Local Variables:
%%% erlang-indent-level: 2
%%% End:
