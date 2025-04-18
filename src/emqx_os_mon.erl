%%--------------------------------------------------------------------
%% Copyright (c) 2019-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_os_mon).

-behaviour(gen_server).

-include("logger.hrl").

-logger_header("[OS_MON]").

-export([start_link/1]).

-export([ get_cpu_check_interval/0
        , set_cpu_check_interval/1
        , get_cpu_high_watermark/0
        , set_cpu_high_watermark/1
        , get_cpu_low_watermark/0
        , set_cpu_low_watermark/1
        , get_mem_check_interval/0
        , set_mem_check_interval/1
        , get_sysmem_high_watermark/0
        , set_sysmem_high_watermark/1
        , get_procmem_high_watermark/0
        , set_procmem_high_watermark/1
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-include("emqx.hrl").

-define(OS_MON, ?MODULE).

start_link(Opts) ->
    gen_server:start_link({local, ?OS_MON}, ?MODULE, [Opts], []).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

get_cpu_check_interval() ->
    call(get_cpu_check_interval).

set_cpu_check_interval(Seconds) ->
    call({set_cpu_check_interval, Seconds}).

get_cpu_high_watermark() ->
    call(get_cpu_high_watermark).

set_cpu_high_watermark(Float) ->
    call({set_cpu_high_watermark, Float}).

get_cpu_low_watermark() ->
    call(get_cpu_low_watermark).

set_cpu_low_watermark(Float) ->
    call({set_cpu_low_watermark, Float}).

get_mem_check_interval() ->
    memsup:get_check_interval() div 1000.

set_mem_check_interval(Seconds) when Seconds < 60 ->
    memsup:set_check_interval(1);
set_mem_check_interval(Seconds) ->
    memsup:set_check_interval(Seconds div 60).

get_sysmem_high_watermark() ->
    memsup:get_sysmem_high_watermark().

set_sysmem_high_watermark(Float) ->
    memsup:set_sysmem_high_watermark(Float / 100).

get_procmem_high_watermark() ->
    memsup:get_procmem_high_watermark().

set_procmem_high_watermark(Float) ->
    memsup:set_procmem_high_watermark(Float / 100).

call(Req) ->
    gen_server:call(?OS_MON, Req, infinity).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Opts]) ->
    set_mem_check_interval(proplists:get_value(mem_check_interval, Opts)),
    SysHW = proplists:get_value(sysmem_high_watermark, Opts),
    set_sysmem_high_watermark(SysHW),
    set_procmem_high_watermark(proplists:get_value(procmem_high_watermark, Opts)),
    ensure_system_memory_alarm(SysHW),
    {ok, ensure_check_timer(#{cpu_high_watermark => proplists:get_value(cpu_high_watermark, Opts),
                              cpu_low_watermark => proplists:get_value(cpu_low_watermark, Opts),
                              cpu_check_interval => proplists:get_value(cpu_check_interval, Opts),
                              timer => undefined})}.

handle_call(get_cpu_check_interval, _From, State) ->
    {reply, maps:get(cpu_check_interval, State, undefined), State};

handle_call({set_cpu_check_interval, Seconds}, _From, State) ->
    {reply, ok, State#{cpu_check_interval := Seconds}};

handle_call(get_cpu_high_watermark, _From, State) ->
    {reply, maps:get(cpu_high_watermark, State, undefined), State};

handle_call({set_cpu_high_watermark, Float}, _From, State) ->
    {reply, ok, State#{cpu_high_watermark := Float}};

handle_call(get_cpu_low_watermark, _From, State) ->
    {reply, maps:get(cpu_low_watermark, State, undefined), State};

handle_call({set_cpu_low_watermark, Float}, _From, State) ->
    {reply, ok, State#{cpu_low_watermark := Float}};

handle_call(Req, _From, State) ->
    ?LOG(error, "Unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    ?LOG(error, "Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({timeout, Timer, check}, State = #{timer := Timer,
                                               cpu_high_watermark := CPUHighWatermark,
                                               cpu_low_watermark := CPULowWatermark}) ->
    NState =
    case emqx_vm:cpu_util() of %% TODO: should be improved?
        0 ->
            State#{timer := undefined};
        Busy when Busy > CPUHighWatermark ->
            emqx_alarm:activate(high_cpu_usage, #{usage => Busy,
                                                  high_watermark => CPUHighWatermark,
                                                  low_watermark => CPULowWatermark}),
            ensure_check_timer(State);
        Busy when Busy < CPULowWatermark ->
            emqx_alarm:deactivate(high_cpu_usage),
            ensure_check_timer(State);
        _Busy ->
            ensure_check_timer(State)
    end,
    {noreply, NState};

handle_info(Info, State) ->
    ?LOG(error, "unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #{timer := Timer}) ->
    emqx_misc:cancel_timer(Timer).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

ensure_check_timer(State = #{cpu_check_interval := Interval}) ->
    case erlang:system_info(system_architecture) of
        "x86_64-pc-linux-musl" -> State;
        _ -> State#{timer := emqx_misc:start_timer(timer:seconds(Interval), check)}
    end.

%% At startup, memsup starts first and checks for memory alarms,
%% but emqx_alarm_handler is not yet used instead of alarm_handler,
%% so alarm_handler is used directly for notification (normally emqx_alarm_handler should be used).
%%The internal memsup will no longer trigger events that have been alerted,
%% and there is no exported function to remove the alerted flag,
%% so it can only be checked again at startup.
ensure_system_memory_alarm(HW) ->
    case erlang:whereis(memsup) of
        undefined -> ok;
        _Pid ->
            {Allocated, Total, _Worst} = memsup:get_memory_data(),
            case Total =/= 0 andalso Allocated/Total * 100 > HW of
                true -> emqx_alarm:activate(high_system_memory_usage, #{high_watermark => HW});
                false -> ok
            end
    end.
