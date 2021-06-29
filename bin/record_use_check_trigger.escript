#!/usr/bin/env escript
%% -*- erlang -*-
%%! +A0

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

main([]) ->
  AppStrings = string:tokens(os:getenv("OUR_APPS"), " "),
  Directories = [code:lib_dir(list_to_atom(AppString), ebin) || AppString <- AppStrings],
  Issues = record_use_check:gather_violations(Directories),
  ReportableIssues =
    case os:getenv("BUILD") of
      "test" -> Issues;
      _ -> lists:filter(fun record_use_check:is_reportable_in_non_test_builds/1, Issues)
    end,
  lists:foreach(fun record_use_check:handle_violation/1, ReportableIssues),
  case lists:any(fun record_use_check:is_real_violation/1, ReportableIssues) of
    false -> ok;
    true  -> halt(1)
  end.
