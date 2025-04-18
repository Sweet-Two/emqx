%%--------------------------------------------------------------------
%% Copyright (c) 2017-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_app).

-behaviour(application).

-export([ start/2
        , prep_stop/1
        , stop/1
        , get_description/0
        , get_release/0
        ]).

-define(APP, emqx).

-include("emqx_release.hrl").

%%--------------------------------------------------------------------
%% Application callbacks
%%--------------------------------------------------------------------

start(_Type, _Args) ->
    set_backtrace_depth(),
    print_otp_version_warning(),
    print_banner(),
    %% Load application first for ekka_mnesia scanner
    _ = load_ce_modules(),
    ekka:start(),
    {ok, Sup} = emqx_sup:start_link(),
    ok = start_autocluster(),
    %% We need to make sure that emqx's listeners start before plugins
    %% and modules. Since if the emqx-conf module/plugin is enabled, it will
    %% try to start or update the listeners with the latest configuration
    emqx_boot:is_enabled(listeners) andalso (ok = emqx_listeners:start()),
    ok = emqx_plugins:init(),
    _ = emqx_plugins:load(),
    _ = start_ce_modules(),
    register(emqx, self()),
    print_vsn(),
    {ok, Sup}.

prep_stop(_State) ->
    ok = emqx_alarm_handler:unload(),
    emqx_boot:is_enabled(listeners)
      andalso emqx_listeners:stop().

stop(_State) ->
    ok.

set_backtrace_depth() ->
    Depth = application:get_env(?APP, backtrace_depth, 16),
    _ = erlang:system_flag(backtrace_depth, Depth),
    ok.

-ifndef(EMQX_ENTERPRISE).
load_ce_modules() ->
    application:load(emqx_modules).
start_ce_modules() ->
    application:ensure_all_started(emqx_modules).
-else.
load_ce_modules() ->
    ok.
start_ce_modules() ->
    ok.
-endif.

%%--------------------------------------------------------------------
%% Print Banner
%%--------------------------------------------------------------------

-if(?OTP_RELEASE> 22).
print_otp_version_warning() -> ok.
-else.
print_otp_version_warning() ->
    io:format("WARNING: Running on Erlang/OTP version ~p. Recommended: 23~n",
              [?OTP_RELEASE]).
-endif. % OTP_RELEASE

-ifndef(TEST).

print_banner() ->
    io:format("Starting ~s on node ~s~n", [?APP, node()]).

print_vsn() ->
    io:format("~s ~s is running now!~n", [get_description(), get_release()]).

-else. % TEST

print_vsn() ->
    ok.

print_banner() ->
    ok.

-endif. % TEST

get_description() ->
    {ok, Descr0} = application:get_key(?APP, description),
    case os:getenv("EMQX_DESCRIPTION") of
        false -> Descr0;
        "" -> Descr0;
        Str -> string:strip(Str, both, $\n)
    end.

get_release() ->
    case lists:keyfind(emqx_vsn, 1, ?MODULE:module_info(compile)) of
        false ->    %% For TEST build or depedency build.
            release_in_macro();
        {_, Vsn} -> %% For emqx release build
            VsnStr = release_in_macro(),
            1 = string:str(Vsn, VsnStr), %% assert
            Vsn
    end.

release_in_macro() ->
    element(2, ?EMQX_RELEASE).

%%--------------------------------------------------------------------
%% Autocluster
%%--------------------------------------------------------------------
start_autocluster() ->
    ekka:callback(prepare, fun emqx:shutdown/1),
    ekka:callback(reboot,  fun emqx:reboot/0),
    _ = ekka:autocluster(?APP), %% returns 'ok' or a pid or 'any()' as in spec
    ok.
