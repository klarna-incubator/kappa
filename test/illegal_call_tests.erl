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
-module(illegal_call_tests).

-include_lib("eunit/include/eunit.hrl").

illegal_call_test_() ->
  %% Use a foreach with no tests: we don't want to run any tests here,
  %% just have an illegal call to meck:new/1. Unfortunately, xref
  %% crashes if we want to check illegal calls to a function that
  %% either doesn't exist or not called from anywhere.
  %%
  %% So this is a deliberately created illegal call that needs to
  %% exist, so we can check that no more occurrences of this call
  %% exist in our code.
  { foreach
  , fun () -> meck:new(kappa) end
  , fun (_) -> meck:unload(kappa) end
  , []
  }.

%%% Local Variables:
%%% erlang-indent-level: 2
%%% End:
