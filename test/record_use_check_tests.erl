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
-module(record_use_check_tests).
-include_lib("eunit/include/eunit.hrl").

test_module(test1) ->
  code_analysis_test_lib:erlang_code_to_abst(
    "-module(test1).\n"
    "f1() -> #record.field.\n");
test_module(test2) ->
  code_analysis_test_lib:erlang_code_to_abst(
    "-module(test2).\n"
    "f1() -> #record.field.\n"
    "f2(R) -> R#record.field.\n"
    "f3(R, V) -> R#record{field = V}.\n");
test_module(test3) ->
  %% Approximation of what an included hrl looks like in the abstract
  %% code.
  [Head | Rest] =
  code_analysis_test_lib:erlang_code_to_abst(
    "-module(test3).\n"
    "\n"
    "f1() -> #record.field.\n"),
  [ Head
  , { attribute
    , 1
    , file
    , {"/home/user/git/release/lib/application/include/hrl.hrl", 1}
    }
  , { attribute
    , 2
    , file
    , {"./test3.erl", 2}
    }
  | Rest
  ].

gather_and_divide_violations(Modules, Rules) ->
  RawList = record_use_check:gather_violations( Modules
                                              , fun test_module/1
                                              , Rules
                                              ),
  lists:partition(fun record_use_check:is_real_violation/1, RawList).

gather_violations_test_() ->
  %% No modules, no rules, no violations
  [ ?_assertMatch( {[], []}
                 , gather_and_divide_violations(
                      []
                    , []
                    )
                 )
  %% A module, but no rules, no violations
  , ?_assertMatch( {[], []}
                 , gather_and_divide_violations(
                       [test1]
                     , []
                    )
                 )
  %% A module, a rule that it violates, one violation, calling for
  %% immediate action
  , ?_assertMatch( {[_], []}
                 , gather_and_divide_violations(
                      [test1]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          ]
                        }
                      ]
                    )
                 )
  %% A module, a rule that it does not violate, no violations
  , ?_assertMatch( {[], []}
                 , gather_and_divide_violations(
                      [test1]
                    , [ { {record2, field}
                        , [ {access_modules, [other]}
                          ]
                        }
                      ]
                    )
                 )
  %% A module, a rule that lists it as an access module, no violations
  , ?_assertMatch( {[], []}
                 , gather_and_divide_violations(
                      [test1]
                    , [ { {record, field}
                        , [ {access_modules, [test1]}
                          ]
                        }
                      ]
                    )
                 )
  %% A module, a rule that lists it as a legacy exception, no violations
  , ?_assertMatch( {[], []}
                 , gather_and_divide_violations(
                      [test1]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          , {legacy_users, [ {test1, 1}
                                           ]
                            }
                          ]
                        }
                      ]
                    )
                 )
  %% A module, a rule that it violates 3 times, 3 violations, each one
  %% calling for immediate action
  , ?_assertMatch( {[_, _, _], []}
                 , gather_and_divide_violations(
                      [test2]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          ]
                        }
                      ]
                    )
                 )
  %% A module with three accesses, a rule that lists it as a legacy
  %% exception with three accesses, no violations
  , ?_assertMatch( {[], []}
                 , gather_and_divide_violations(
                      [test2]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          , {legacy_users, [ {test2, 3}
                                           ]
                            }
                          ]
                        }
                      ]
                    )
                 )
  %% A module with three accesses, a rule that lists it as a legacy
  %% exception with two accesses, one violation, calling for immediate
  %% action
  , ?_assertMatch( {[_], []}
                 , gather_and_divide_violations(
                      [test2]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          , {legacy_users, [ {test2, 2}
                                           ]
                            }
                          ]
                        }
                      ]
                    )
                 )
  %% A module with three accesses, a rule that lists it as a legacy
  %% exception with four accesses, one violation, calling for
  %% immediate action
  , ?_assertMatch( {[_], []}
                 , gather_and_divide_violations(
                      [test2]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          , {legacy_users, [ {test2, 4}
                                           ]
                            }
                          ]
                        }
                      ]
                    )
                 )
  %% A module with a use of one record field, a rule regarding another
  %% record field, an exception for one use in that module, one
  %% violation, calling for immediate action.
  , ?_assertMatch( {[_], []}
                 , gather_and_divide_violations(
                      [test1]
                    , [ { {record, other_field}
                        , [ {access_modules, [other]}
                          , {legacy_users, [ {test1, 1}
                                           ]
                            }
                          ]
                        }
                      ]
                    )
                 )
  %% A module with a use of one record field, a rule regarding another
  %% record field, an exception for one use in another module, one
  %% violation, calling for immediate action.
  , ?_assertMatch( {[_], []}
                 , gather_and_divide_violations(
                      [test1]
                    , [ { {record, other_field}
                        , [ {access_modules, [other]}
                          , {legacy_users, [ {test2, 1}
                                           ]
                            }
                          ]
                        }
                      ]
                    )
                 )
  %% A module with one access of each type, a rule that excepts one
  %% access type, two violations, each calling for immediate action
  %% (three test for three access types)
  , ?_assertMatch( {[_, _], []}
                 , gather_and_divide_violations(
                      [test2]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          , { excepted_access_types
                            , [ set
                              ]
                            }
                          ]
                        }
                      ]
                    )
                 )
  , ?_assertMatch( {[_, _], []}
                 , gather_and_divide_violations(
                      [test2]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          , { excepted_access_types
                            , [ get
                              ]
                            }
                          ]
                        }
                      ]
                    )
                 )
  , ?_assertMatch( {[_, _], []}
                 , gather_and_divide_violations(
                      [test2]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          , { excepted_access_types
                            , [ index
                              ]
                            }
                          ]
                        }
                      ]
                    )
                 )
  %% Two modules, a rule that they violate four times in total, four
  %% violations, each one calling for immediate action.
  , ?_assertMatch( {[_, _, _, _], []}
                 , gather_and_divide_violations(
                      [test1, test2]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          ]
                        }
                      ]
                    )
                 )
  %% A module with a use and a reference to a hrl, a rule specifying
  %% that hrl, one violation, calling for immediate action.
  , ?_assertMatch( {[_], []}
                 , gather_and_divide_violations(
                      [test3]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          , {hrl, "hrl.hrl"}
                          ]
                        }
                       ]
                    )
                 )
  %% A module with a use and no reference to a hrl, a rule specifying
  %% a hrl, no violation.
  , ?_assertMatch( {[], []}
                 , gather_and_divide_violations(
                      [test1]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          , {hrl, "hrl.hrl"}
                          ]
                        }
                      ]
                    )
                 )
  %% A module with a use and a reference to a hrl, a rule specifying
  %% another hrl, no violation.
  , ?_assertMatch( {[], []}
                 , gather_and_divide_violations(
                      [test3]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          , {hrl, "x.hrl"}
                          ]
                        }
                      ]
                    )
                 )
  %% A module with a use and a reference to a hrl, a rule specifying
  %% that hrl with a path fragment, one violation, calling for
  %% immediate action.
  , ?_assertMatch( {[_], []}
                 , gather_and_divide_violations(
                      [test3]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          , {hrl, "application/include/hrl.hrl"}
                          ]
                        }
                      ]
                    )
                 )
  %% A module with a use and a reference to a hrl, a rule specifying
  %% a hrl by the same name but a different path, no violation.
  , ?_assertMatch( {[], []}
                 , gather_and_divide_violations(
                      [test3]
                    , [ { {record, field}
                        , [ {access_modules, [other]}
                          , {hrl, "application/exclude/hrl.hrl"}
                          ]
                        }
                      ]
                    )
                 )
  ].


current_legacy_use_test_() ->
  %% No modules, no legacy uses
  [ ?_assertEqual( []
                 , record_use_check:current_legacy_use( {record, field}
                                                      , [other]
                                                      , []
                                                      , []
                                                      , fun test_module/1
                                                      )
                 )
  %% Module with one use, reported as one legacy use
  , ?_assertEqual( [{test1, 1}]
                 , record_use_check:current_legacy_use( {record, field}
                                                      , [other]
                                                      , []
                                                      , [test1]
                                                      , fun test_module/1
                                                      )
                 )
  %% One module recognized as access module, no reported legacy use
  , ?_assertEqual( []
                 , record_use_check:current_legacy_use( {record, field}
                                                      , [test1]
                                                      , []
                                                      , [test1]
                                                      , fun test_module/1
                                                      )
                 )
  %% One module with one 'index' use, 'index' excluded from
  %% consideration, no reported legacy use
  , ?_assertEqual( []
                 , record_use_check:current_legacy_use( {record, field}
                                                      , [other]
                                                      , [index]
                                                      , [test1]
                                                      , fun test_module/1
                                                      )
                 )
  %% One module with one 'index' use, another type excluded from
  %% consideration, one legacy use reported
  , ?_assertEqual( [{test1, 1}]
                 , record_use_check:current_legacy_use( {record, field}
                                                      , [other]
                                                      , [get]
                                                      , [test1]
                                                      , fun test_module/1
                                                      )
                 )
  %% One module with one use, one with three uses, reported separately
  , ?_assertEqual( [ {test1, 1}
                   , {test2, 3}
                   ]
                 , record_use_check:current_legacy_use( {record, field}
                                                      , [other]
                                                      , []
                                                      , [test1, test2]
                                                      , fun test_module/1
                                                      )
                 )
  ].

%%% Local Variables:
%%% erlang-indent-level: 2
%%% End:
