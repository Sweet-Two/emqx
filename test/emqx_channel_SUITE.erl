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

-module(emqx_channel_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").
-include_lib("eunit/include/eunit.hrl").


all() -> emqx_ct:all(?MODULE).

%%--------------------------------------------------------------------
%% CT Callbacks
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    %% CM Meck
    ok = meck:new(emqx_cm, [passthrough, no_history, no_link]),
    %% Access Control Meck
    ok = meck:new(emqx_access_control, [passthrough, no_history, no_link]),
    ok = meck:expect(emqx_access_control, authenticate,
                     fun(_) -> {ok, #{auth_result => success}} end),
    ok = meck:expect(emqx_access_control, check_acl, fun(_, _, _) -> allow end),
    %% Broker Meck
    ok = meck:new(emqx_broker, [passthrough, no_history, no_link]),
    %% Hooks Meck
    ok = meck:new(emqx_hooks, [passthrough, no_history, no_link]),
    ok = meck:expect(emqx_hooks, run, fun(_Hook, _Args) -> ok end),
    ok = meck:expect(emqx_hooks, run_fold, fun(_Hook, _Args, Acc) -> Acc end),
    %% Session Meck
    ok = meck:new(emqx_session, [passthrough, no_history, no_link]),
    %% Metrics
    ok = meck:new(emqx_metrics, [passthrough, no_history, no_link]),
    ok = meck:expect(emqx_metrics, inc, fun(_) -> ok end),
    ok = meck:expect(emqx_metrics, inc, fun(_, _) -> ok end),
    Config.

end_per_suite(_Config) ->
    meck:unload([emqx_access_control,
                 emqx_metrics,
                 emqx_session,
                 emqx_broker,
                 emqx_hooks,
                 emqx_cm
                ]).

init_per_testcase(_TestCase, Config) ->
    meck:new(emqx_zone, [passthrough, no_history, no_link]),
    Config.

end_per_testcase(_TestCase, Config) ->
    meck:unload([emqx_zone]),
    Config.

%%--------------------------------------------------------------------
%% Test cases for channel info/stats/caps
%%--------------------------------------------------------------------

t_chan_info(_) ->
    #{conn_state := connected,
      clientinfo := ClientInfo
     } = emqx_channel:info(channel()),
    ?assertEqual(clientinfo(), ClientInfo).

t_chan_caps(_) ->
     ?assertMatch(#{
        max_clientid_len := 65535,
        max_qos_allowed := 2,
        max_topic_alias := 65535,
        max_topic_levels := Level,
        retain_available := true,
        shared_subscription := true,
        subscription_identifiers := true,
        wildcard_subscription := true
      } when is_integer(Level), emqx_channel:caps(channel())).

%%--------------------------------------------------------------------
%% Test cases for channel handle_in
%%--------------------------------------------------------------------

t_handle_in_connect_packet_sucess(_) ->
    ok = meck:expect(emqx_cm, open_session,
                     fun(true, _ClientInfo, _ConnInfo) ->
                             {ok, #{session => session(), present => false}}
                     end),
    IdleChannel = channel(#{conn_state => idle}),
    {ok, [{event, connected}, {connack, ?CONNACK_PACKET(?RC_SUCCESS, 0, _)}], Channel} =
        emqx_channel:handle_in(?CONNECT_PACKET(connpkt()), IdleChannel),
    ClientInfo = emqx_channel:info(clientinfo, Channel),
    ?assertMatch(#{clientid := <<"clientid">>,
                   username := <<"username">>
                  }, ClientInfo),
    ?assertEqual(connected, emqx_channel:info(conn_state, Channel)).

t_handle_in_unexpected_connect_packet(_) ->
    Channel = emqx_channel:set_field(conn_state, connected, channel()),
    Packet = ?DISCONNECT_PACKET(?RC_PROTOCOL_ERROR),
    {ok, [{outgoing, Packet}, {close, protocol_error}], Channel} =
        emqx_channel:handle_in(?CONNECT_PACKET(connpkt()), Channel).

t_handle_in_unexpected_packet(_) ->
    Channel = emqx_channel:set_field(conn_state, idle, channel()),
    Packet = ?DISCONNECT_PACKET(?RC_PROTOCOL_ERROR),
    {ok, [{outgoing, Packet}, {close, protocol_error}], Channel} =
        emqx_channel:handle_in(?PUBLISH_PACKET(?QOS_0), Channel).

t_handle_in_connect_auth_failed(_) ->
    ConnPkt = #mqtt_packet_connect{
                                proto_name  = <<"MQTT">>,
                                proto_ver   = ?MQTT_PROTO_V5,
                                is_bridge   = false,
                                clean_start = true,
                                keepalive   = 30,
                                properties  = #{
                                            'Authentication-Method' => <<"failed_auth_method">>,
                                            'Authentication-Data' => <<"failed_auth_data">>
                                            },
                                clientid    = <<"clientid">>,
                                username    = <<"username">>
                                },
    {shutdown, not_authorized, ?CONNACK_PACKET(?RC_NOT_AUTHORIZED), _} =
        emqx_channel:handle_in(?CONNECT_PACKET(ConnPkt), channel(#{conn_state => idle})).

t_handle_in_continue_auth(_) ->
    Properties = #{
                'Authentication-Method' => <<"failed_auth_method">>,
                'Authentication-Data' => <<"failed_auth_data">>
                },
    {shutdown, bad_authentication_method, ?CONNACK_PACKET(?RC_BAD_AUTHENTICATION_METHOD), _} =
        emqx_channel:handle_in(?AUTH_PACKET(?RC_CONTINUE_AUTHENTICATION,Properties), channel()),
    {shutdown, not_authorized, ?CONNACK_PACKET(?RC_NOT_AUTHORIZED), _} =
        emqx_channel:handle_in(
          ?AUTH_PACKET(?RC_CONTINUE_AUTHENTICATION,Properties),
          channel(#{conninfo => #{proto_ver => ?MQTT_PROTO_V5, conn_props => Properties}})
        ).

t_handle_in_re_auth(_) ->
    Properties = #{
                'Authentication-Method' => <<"failed_auth_method">>,
                'Authentication-Data' => <<"failed_auth_data">>
                },
    {ok, [{outgoing, ?DISCONNECT_PACKET(?RC_BAD_AUTHENTICATION_METHOD)},
          {close, bad_authentication_method}], _} =
        emqx_channel:handle_in(
          ?AUTH_PACKET(?RC_RE_AUTHENTICATE,Properties),
          channel()
        ),
    {ok, [{outgoing, ?DISCONNECT_PACKET(?RC_BAD_AUTHENTICATION_METHOD)},
          {close, bad_authentication_method}], _} =
        emqx_channel:handle_in(
          ?AUTH_PACKET(?RC_RE_AUTHENTICATE,Properties),
          channel(#{conninfo => #{proto_ver => ?MQTT_PROTO_V5, conn_props => undefined}})
        ),
    {ok, [{outgoing, ?DISCONNECT_PACKET(?RC_NOT_AUTHORIZED)}, {close, not_authorized}], _} =
        emqx_channel:handle_in(
          ?AUTH_PACKET(?RC_RE_AUTHENTICATE,Properties),
          channel(#{conninfo => #{proto_ver => ?MQTT_PROTO_V5, conn_props => Properties}})
        ).

t_handle_in_qos0_publish(_) ->
    ok = meck:expect(emqx_broker, publish, fun(_) -> [] end),
    Channel = channel(#{conn_state => connected}),
    Publish = ?PUBLISH_PACKET(?QOS_0, <<"topic">>, undefined, <<"payload">>),
    {ok, _NChannel} = emqx_channel:handle_in(Publish, Channel).

t_handle_in_qos1_publish(_) ->
    ok = meck:expect(emqx_broker, publish, fun(_) -> [] end),
    Publish = ?PUBLISH_PACKET(?QOS_1, <<"topic">>, 1, <<"payload">>),
    {ok, ?PUBACK_PACKET(1, ?RC_NO_MATCHING_SUBSCRIBERS), _Channel} =
        emqx_channel:handle_in(Publish, channel(#{conn_state => connected})).

t_handle_in_qos2_publish(_) ->
    ok = meck:expect(emqx_broker, publish, fun(_) -> [{node(), <<"topic">>, {ok, 1}}] end),
    Channel = channel(#{conn_state => connected, session => session()}),
    Publish1 = ?PUBLISH_PACKET(?QOS_2, <<"topic">>, 1, <<"payload">>),
    {ok, ?PUBREC_PACKET(1, ?RC_SUCCESS), Channel1} =
        emqx_channel:handle_in(Publish1, Channel),
    ok = meck:expect(emqx_broker, publish, fun(_) -> [] end),
    Publish2 = ?PUBLISH_PACKET(?QOS_2, <<"topic">>, 2, <<"payload">>),
    {ok, ?PUBREC_PACKET(2, ?RC_NO_MATCHING_SUBSCRIBERS), Channel2} =
        emqx_channel:handle_in(Publish2, Channel1),
    ?assertEqual(2, proplists:get_value(awaiting_rel_cnt, emqx_channel:stats(Channel2))).

t_handle_in_qos2_publish_with_error_return(_) ->
    ok = meck:expect(emqx_metrics, inc, fun(_) -> ok end),
    ok = meck:expect(emqx_broker, publish, fun(_) -> [] end),
    Session = session(#{max_awaiting_rel => 2, awaiting_rel => #{1 => 1}}),
    Channel = channel(#{conn_state => connected, session => Session}),
    Publish1 = ?PUBLISH_PACKET(?QOS_2, <<"topic">>, 1, <<"payload">>),
    {ok, ?PUBREC_PACKET(1, ?RC_PACKET_IDENTIFIER_IN_USE), Channel} =
        emqx_channel:handle_in(Publish1, Channel),
    Publish2 = ?PUBLISH_PACKET(?QOS_2, <<"topic">>, 2, <<"payload">>),
    {ok, ?PUBREC_PACKET(2, ?RC_NO_MATCHING_SUBSCRIBERS), Channel1} =
        emqx_channel:handle_in(Publish2, Channel),
    Publish3 = ?PUBLISH_PACKET(?QOS_2, <<"topic">>, 3, <<"payload">>),
    {ok, [{outgoing, ?DISCONNECT_PACKET(?RC_RECEIVE_MAXIMUM_EXCEEDED)},
          {close, receive_maximum_exceeded}], Channel1} =
        emqx_channel:handle_in(Publish3, Channel1).

t_handle_in_puback_ok(_) ->
    Msg = emqx_message:make(<<"t">>, <<"payload">>),
    ok = meck:expect(emqx_session, puback,
                     fun(_, _PacketId, Session) -> {ok, Msg, Session} end),
    Channel = channel(#{conn_state => connected}),
    {ok, _NChannel} = emqx_channel:handle_in(?PUBACK_PACKET(1, ?RC_SUCCESS), Channel).
    % ?assertEqual(#{puback_in => 1}, emqx_channel:info(pub_stats, NChannel)).

t_handle_in_puback_id_in_use(_) ->
    ok = meck:expect(emqx_session, puback,
                     fun(_, _, _Session) ->
                             {error, ?RC_PACKET_IDENTIFIER_IN_USE}
                     end),
    {ok, _Channel} = emqx_channel:handle_in(?PUBACK_PACKET(1, ?RC_SUCCESS), channel()).
    % ?assertEqual(#{puback_in => 1}, emqx_channel:info(pub_stats, Channel)).

t_handle_in_puback_id_not_found(_) ->
    ok = meck:expect(emqx_session, puback,
                     fun(_, _, _Session) ->
                             {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
                     end),
    {ok, _Channel} = emqx_channel:handle_in(?PUBACK_PACKET(1, ?RC_SUCCESS), channel()).
    % ?assertEqual(#{puback_in => 1}, emqx_channel:info(pub_stats, Channel)).

t_bad_receive_maximum(_) ->
    ok = meck:expect(emqx_cm, open_session,
                     fun(true, _ClientInfo, _ConnInfo) ->
                             {ok, #{session => session(), present => false}}
                     end),
    ok = meck:expect(emqx_zone, response_information, fun(_) -> test end),
    C1 = channel(#{conn_state => idle}),
    {shutdown, protocol_error, _, _} =
        emqx_channel:handle_in(
          ?CONNECT_PACKET(connpkt(#{'Receive-Maximum' => 0})),
          C1
        ).

t_override_client_receive_maximum(_) ->
    ok = meck:expect(emqx_cm, open_session,
                     fun(true, _ClientInfo, _ConnInfo) ->
                             {ok, #{session => session(), present => false}}
                     end),
    ok = meck:expect(emqx_zone, response_information, fun(_) -> test end),
    ok = meck:expect(emqx_zone, max_inflight, fun(_) -> 0 end),
    C1 = channel(#{conn_state => idle}),
    ClientCapacity = 2,
    {ok, [{event, connected}, _ConnAck], C2} =
        emqx_channel:handle_in(
          ?CONNECT_PACKET(connpkt(#{'Receive-Maximum' => ClientCapacity})),
          C1
        ),
    ConnInfo = emqx_channel:info(conninfo, C2),
    ?assertEqual(ClientCapacity, maps:get(receive_maximum, ConnInfo)).

t_handle_in_pubrec_ok(_) ->
    Msg = emqx_message:make(test,?QOS_2, <<"t">>, <<"payload">>),
    ok = meck:expect(emqx_session, pubrec, fun(_, Session) -> {ok, Msg, Session} end),
    Channel = channel(#{conn_state => connected}),
    {ok, ?PUBREL_PACKET(1, ?RC_SUCCESS), _Channel1} =
        emqx_channel:handle_in(?PUBREC_PACKET(1, ?RC_SUCCESS), Channel).

t_handle_in_pubrec_id_in_use(_) ->
    ok = meck:expect(emqx_session, pubrec,
                     fun(_, _Session) ->
                             {error, ?RC_PACKET_IDENTIFIER_IN_USE}
                     end),
    {ok, ?PUBREL_PACKET(1, ?RC_PACKET_IDENTIFIER_IN_USE), _Channel} =
        emqx_channel:handle_in(?PUBREC_PACKET(1, ?RC_SUCCESS), channel()).

t_handle_in_pubrec_id_not_found(_) ->
    ok = meck:expect(emqx_session, pubrec,
                     fun(_, _Session) ->
                             {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
                     end),
    {ok, ?PUBREL_PACKET(1, ?RC_PACKET_IDENTIFIER_NOT_FOUND), _Channel} =
        emqx_channel:handle_in(?PUBREC_PACKET(1, ?RC_SUCCESS), channel()).

t_handle_in_pubrel_ok(_) ->
    ok = meck:expect(emqx_session, pubrel, fun(_, Session) -> {ok, Session} end),
    Channel = channel(#{conn_state => connected}),
    {ok, ?PUBCOMP_PACKET(1, ?RC_SUCCESS), _Channel1} =
        emqx_channel:handle_in(?PUBREL_PACKET(1, ?RC_SUCCESS), Channel).

t_handle_in_pubrel_not_found_error(_) ->
    ok = meck:expect(emqx_session, pubrel,
                     fun(_PacketId, _Session) ->
                             {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
                     end),
    {ok, ?PUBCOMP_PACKET(1, ?RC_PACKET_IDENTIFIER_NOT_FOUND), _Channel} =
        emqx_channel:handle_in(?PUBREL_PACKET(1, ?RC_SUCCESS), channel()).

t_handle_in_pubcomp_ok(_) ->
    ok = meck:expect(emqx_session, pubcomp, fun(_, _, Session) -> {ok, Session} end),
    {ok, _Channel} = emqx_channel:handle_in(?PUBCOMP_PACKET(1, ?RC_SUCCESS), channel()).
    % ?assertEqual(#{pubcomp_in => 1}, emqx_channel:info(pub_stats, Channel)).

t_handle_in_pubcomp_not_found_error(_) ->
    ok = meck:expect(emqx_session, pubcomp,
                     fun(_, _PacketId, _Session) ->
                             {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
                     end),
    Channel = channel(#{conn_state => connected}),
    {ok, _Channel1} = emqx_channel:handle_in(?PUBCOMP_PACKET(1, ?RC_SUCCESS), Channel).

t_handle_in_subscribe(_) ->
    ok = meck:expect(emqx_session, subscribe,
                     fun(_, _, _, Session) -> {ok, Session} end),
    Channel = channel(#{conn_state => connected}),
    TopicFilters = [{<<"+">>, ?DEFAULT_SUBOPTS}],
    Subscribe = ?SUBSCRIBE_PACKET(1, #{}, TopicFilters),
    Replies = [{outgoing, ?SUBACK_PACKET(1, [?QOS_0])}, {event, updated}],
    {ok, Replies, _Chan} = emqx_channel:handle_in(Subscribe, Channel).

t_handle_in_unsubscribe(_) ->
    ok = meck:expect(emqx_session, unsubscribe,
                     fun(_, _, _, Session) ->
                             {ok, Session}
                     end),
    Channel = channel(#{conn_state => connected}),
    {ok, [{outgoing, ?UNSUBACK_PACKET(1)}, {event, updated}], _Chan} =
        emqx_channel:handle_in(?UNSUBSCRIBE_PACKET(1, #{}, [<<"+">>]), Channel).

t_handle_in_pingreq(_) ->
    {ok, ?PACKET(?PINGRESP), _Channel} =
        emqx_channel:handle_in(?PACKET(?PINGREQ), channel()).

t_handle_in_disconnect(_) ->
    Packet = ?DISCONNECT_PACKET(?RC_SUCCESS),
    Channel = channel(#{conn_state => connected}),
    {ok, {close, normal}, Channel1} = emqx_channel:handle_in(Packet, Channel),
    ?assertEqual(undefined, emqx_channel:info(will_msg, Channel1)).

t_handle_in_auth(_) ->
    Channel = channel(#{conn_state => connected}),
    Packet = ?DISCONNECT_PACKET(?RC_IMPLEMENTATION_SPECIFIC_ERROR),
    {ok, [{outgoing, Packet}, {close, implementation_specific_error}], Channel} =
        emqx_channel:handle_in(?AUTH_PACKET(), Channel).

t_handle_in_frame_error(_) ->
    IdleChannel = channel(#{conn_state => idle}),
    {shutdown, frame_too_large, _Chan} =
        emqx_channel:handle_in({frame_error, frame_too_large}, IdleChannel),
    ConnectingChan =  channel(#{conn_state => connecting}),
    ConnackPacket = ?CONNACK_PACKET(?RC_PACKET_TOO_LARGE),
    {shutdown, frame_too_large, ConnackPacket, _} =
        emqx_channel:handle_in({frame_error, frame_too_large}, ConnectingChan),
    DisconnectPacket = ?DISCONNECT_PACKET(?RC_PACKET_TOO_LARGE),
    ConnectedChan = channel(#{conn_state => connected}),
    {ok, [{outgoing, DisconnectPacket}, {close, frame_too_large}], _} =
        emqx_channel:handle_in({frame_error, frame_too_large}, ConnectedChan),
    DisconnectedChan = channel(#{conn_state => disconnected}),
    {ok, DisconnectedChan} =
        emqx_channel:handle_in({frame_error, frame_too_large}, DisconnectedChan).

t_handle_in_expected_packet(_) ->
    Packet = ?DISCONNECT_PACKET(?RC_PROTOCOL_ERROR),
    {ok, [{outgoing, Packet}, {close, protocol_error}], _Chan} =
        emqx_channel:handle_in(packet, channel()).

t_process_connect(_) ->
    ok = meck:expect(emqx_cm, open_session,
                     fun(true, _ClientInfo, _ConnInfo) ->
                             {ok, #{session => session(), present => false}}
                     end),
    {ok, [{event, connected}, {connack, ?CONNACK_PACKET(?RC_SUCCESS)}], _Chan} =
        emqx_channel:process_connect(#{}, channel(#{conn_state => idle})).

t_process_publish_qos0(_) ->
    ok = meck:expect(emqx_broker, publish, fun(_) -> [] end),
    Publish = ?PUBLISH_PACKET(?QOS_0, <<"t">>, 1, <<"payload">>),
    {ok, _Channel} = emqx_channel:process_publish(Publish, channel()).

t_process_publish_qos1(_) ->
    ok = meck:expect(emqx_broker, publish, fun(_) -> [] end),
    Publish = ?PUBLISH_PACKET(?QOS_1, <<"t">>, 1, <<"payload">>),
    {ok, ?PUBACK_PACKET(1, ?RC_NO_MATCHING_SUBSCRIBERS), _Channel} =
        emqx_channel:process_publish(Publish, channel()).

t_process_subscribe(_) ->
    ok = meck:expect(emqx_session, subscribe, fun(_, _, _, Session) -> {ok, Session} end),
    TopicFilters = [ TopicFilter = {<<"+">>, ?DEFAULT_SUBOPTS}],
    {[{TopicFilter, ?RC_SUCCESS}], _Channel} =
        emqx_channel:process_subscribe(TopicFilters, #{}, channel()).

t_process_unsubscribe(_) ->
    ok = meck:expect(emqx_session, unsubscribe, fun(_, _, _, Session) -> {ok, Session} end),
    TopicFilters = [{<<"+">>, ?DEFAULT_SUBOPTS}],
    {[?RC_SUCCESS], _Channel} = emqx_channel:process_unsubscribe(TopicFilters, #{}, channel()).

t_quota_qos0(_) ->
    esockd_limiter:start_link(), Cnter = counters:new(1, []),
    ok = meck:expect(emqx_broker, publish, fun(_) -> [{node(), <<"topic">>, {ok, 4}}] end),
    ok = meck:expect(
           emqx_metrics,
           inc,
           fun('packets.publish.dropped') -> counters:add(Cnter, 1, 1) end
         ),
    ok = meck:expect(
           emqx_metrics,
           val,
           fun('packets.publish.dropped') -> counters:get(Cnter, 1) end
          ),
    Chann = channel(#{conn_state => connected, quota => quota()}),
    Pub = ?PUBLISH_PACKET(?QOS_0, <<"topic">>, undefined, <<"payload">>),

    M1 = emqx_metrics:val('packets.publish.dropped'),
    {ok, Chann1} = emqx_channel:handle_in(Pub, Chann),
    {ok, Chann2} = emqx_channel:handle_in(Pub, Chann1),
    M1 = emqx_metrics:val('packets.publish.dropped') - 1,
    {ok, Chann3} = emqx_channel:handle_timeout(ref, expire_quota_limit, Chann2),
    {ok, _} = emqx_channel:handle_in(Pub, Chann3),
    M1 = emqx_metrics:val('packets.publish.dropped') - 1,

    ok = meck:expect(emqx_metrics, inc, fun(_) -> ok end),
    ok = meck:expect(emqx_metrics, inc, fun(_, _) -> ok end),
    esockd_limiter:stop().

t_quota_qos1(_) ->
    esockd_limiter:start_link(),
    ok = meck:expect(emqx_broker, publish, fun(_) -> [{node(), <<"topic">>, {ok, 4}}] end),
    Chann = channel(#{conn_state => connected, quota => quota()}),
    Pub = ?PUBLISH_PACKET(?QOS_1, <<"topic">>, 1, <<"payload">>),
    %% Quota per connections
    {ok, ?PUBACK_PACKET(1, ?RC_SUCCESS), Chann1} = emqx_channel:handle_in(Pub, Chann),
    {ok, ?PUBACK_PACKET(1, ?RC_QUOTA_EXCEEDED), Chann2} = emqx_channel:handle_in(Pub, Chann1),
    {ok, Chann3} = emqx_channel:handle_timeout(ref, expire_quota_limit, Chann2),
    {ok, ?PUBACK_PACKET(1, ?RC_SUCCESS), Chann4} = emqx_channel:handle_in(Pub, Chann3),
    %% Quota in overall
    {ok, ?PUBACK_PACKET(1, ?RC_QUOTA_EXCEEDED), _} = emqx_channel:handle_in(Pub, Chann4),
    esockd_limiter:stop().

t_quota_qos2(_) ->
    esockd_limiter:start_link(),
    ok = meck:expect(emqx_broker, publish, fun(_) -> [{node(), <<"topic">>, {ok, 4}}] end),
    Chann = channel(#{conn_state => connected, quota => quota()}),
    Pub1 = ?PUBLISH_PACKET(?QOS_2, <<"topic">>, 1, <<"payload">>),
    Pub2 = ?PUBLISH_PACKET(?QOS_2, <<"topic">>, 2, <<"payload">>),
    Pub3 = ?PUBLISH_PACKET(?QOS_2, <<"topic">>, 3, <<"payload">>),
    Pub4 = ?PUBLISH_PACKET(?QOS_2, <<"topic">>, 4, <<"payload">>),
    %% Quota per connections
    {ok, ?PUBREC_PACKET(1, ?RC_SUCCESS), Chann1} = emqx_channel:handle_in(Pub1, Chann),
    {ok, ?PUBREC_PACKET(2, ?RC_QUOTA_EXCEEDED), Chann2} = emqx_channel:handle_in(Pub2, Chann1),
    {ok, Chann3} = emqx_channel:handle_timeout(ref, expire_quota_limit, Chann2),
    {ok, ?PUBREC_PACKET(3, ?RC_SUCCESS), Chann4} = emqx_channel:handle_in(Pub3, Chann3),
    %% Quota in overall
    {ok, ?PUBREC_PACKET(4, ?RC_QUOTA_EXCEEDED), _} = emqx_channel:handle_in(Pub4, Chann4),
    esockd_limiter:stop().

%%--------------------------------------------------------------------
%% Test cases for handle_deliver
%%--------------------------------------------------------------------

t_handle_deliver(_) ->
    Msg0 = emqx_message:make(test, ?QOS_1, <<"t1">>, <<"qos1">>),
    Msg1 = emqx_message:make(test, ?QOS_2, <<"t2">>, <<"qos2">>),
    Delivers = [{deliver, <<"+">>, Msg0}, {deliver, <<"+">>, Msg1}],
    {ok, {outgoing, Packets}, _Ch} = emqx_channel:handle_deliver(Delivers, channel()),
    ?assertEqual([?QOS_1, ?QOS_2], [emqx_packet:qos(Pkt)|| Pkt <- Packets]).

t_handle_deliver_nl(_) ->
    ClientInfo = clientinfo(#{clientid => <<"clientid">>}),
    Session = session(#{subscriptions => #{<<"t1">> => #{nl => 1}}}),
    Channel = channel(#{clientinfo => ClientInfo, session => Session}),
    Msg = emqx_message:make(<<"clientid">>, ?QOS_1, <<"t1">>, <<"qos1">>),
    NMsg = emqx_message:set_flag(nl, Msg),
    {ok, Channel} = emqx_channel:handle_deliver([{deliver, <<"t1">>, NMsg}], Channel).

%%--------------------------------------------------------------------
%% Test cases for handle_out
%%--------------------------------------------------------------------

t_handle_out_publish(_) ->
    Channel = channel(#{conn_state => connected}),
    Pub0 = {undefined, emqx_message:make(<<"t">>, <<"qos0">>)},
    Pub1 = {1, emqx_message:make(<<"c">>, ?QOS_1, <<"t">>, <<"qos1">>)},
    {ok, {outgoing, Packets}, _NChannel} =
        emqx_channel:handle_out(publish, [Pub0, Pub1], Channel),
    ?assertEqual(2, length(Packets)).

t_handle_out_publish_1(_) ->
    Msg = emqx_message:make(<<"clientid">>, ?QOS_1, <<"t">>, <<"payload">>),
    {ok, {outgoing, [?PUBLISH_PACKET(?QOS_1, <<"t">>, 1, <<"payload">>)]}, _Chan}
        = emqx_channel:handle_out(publish, [{1, Msg}], channel()).

t_handle_out_connack_sucess(_) ->
    {ok, [{event, connected}, {connack, ?CONNACK_PACKET(?RC_SUCCESS, 0, _)}], Channel} =
        emqx_channel:handle_out(connack, {?RC_SUCCESS, 0, #{}}, channel()),
    ?assertEqual(connected, emqx_channel:info(conn_state, Channel)).

t_handle_out_connack_response_information(_) ->
    ok = meck:expect(emqx_cm, open_session,
                     fun(true, _ClientInfo, _ConnInfo) ->
                             {ok, #{session => session(), present => false}}
                     end),
    ok = meck:expect(emqx_zone, response_information, fun(_) -> test end),
    IdleChannel = channel(#{conn_state => idle}),
    {ok, [{event, connected},
          {connack, ?CONNACK_PACKET(?RC_SUCCESS, 0, #{'Response-Information' := test})}],
     _} = emqx_channel:handle_in(
            ?CONNECT_PACKET(connpkt(#{'Request-Response-Information' => 1})),
            IdleChannel
          ).

t_handle_out_connack_not_response_information(_) ->
    ok = meck:expect(emqx_cm, open_session,
                     fun(true, _ClientInfo, _ConnInfo) ->
                             {ok, #{session => session(), present => false}}
                     end),
    ok = meck:expect(emqx_zone, response_information, fun(_) -> test end),
    IdleChannel = channel(#{conn_state => idle}),
    {ok, [{event, connected}, {connack, ?CONNACK_PACKET(?RC_SUCCESS, 0, AckProps)}], _} =
        emqx_channel:handle_in(
          ?CONNECT_PACKET(connpkt(#{'Request-Response-Information' => 0})),
          IdleChannel
        ),
    ?assertEqual(false, maps:is_key('Response-Information', AckProps)).

t_handle_out_connack_failure(_) ->
    {shutdown, not_authorized, ?CONNACK_PACKET(?RC_NOT_AUTHORIZED), _Chan} =
        emqx_channel:handle_out(connack, ?RC_NOT_AUTHORIZED, channel()).

t_handle_out_puback(_) ->
    Channel = channel(#{conn_state => connected}),
    {ok, ?PUBACK_PACKET(1, ?RC_SUCCESS), _NChannel} =
        emqx_channel:handle_out(puback, {1, ?RC_SUCCESS}, Channel).

t_handle_out_pubrec(_) ->
    Channel = channel(#{conn_state => connected}),
    {ok, ?PUBREC_PACKET(1, ?RC_SUCCESS), _NChannel} =
        emqx_channel:handle_out(pubrec, {1, ?RC_SUCCESS}, Channel).

t_handle_out_pubrel(_) ->
    Channel = channel(#{conn_state => connected}),
    {ok, ?PUBREL_PACKET(1), Channel1} =
        emqx_channel:handle_out(pubrel, {1, ?RC_SUCCESS}, Channel),
    {ok, ?PUBREL_PACKET(2, ?RC_SUCCESS), _Channel2} =
        emqx_channel:handle_out(pubrel, {2, ?RC_SUCCESS}, Channel1).

t_handle_out_pubcomp(_) ->
    {ok, ?PUBCOMP_PACKET(1, ?RC_SUCCESS), _Channel} =
        emqx_channel:handle_out(pubcomp, {1, ?RC_SUCCESS}, channel()).

t_handle_out_suback(_) ->
    Replies = [{outgoing, ?SUBACK_PACKET(1, [?QOS_2])}, {event, updated}],
    {ok, Replies, _Chan} = emqx_channel:handle_out(suback, {1, [?QOS_2]}, channel()).

t_handle_out_unsuback(_) ->
    Replies = [{outgoing, ?UNSUBACK_PACKET(1, [?RC_SUCCESS])}, {event, updated}],
    {ok, Replies, _Chan} = emqx_channel:handle_out(unsuback, {1, [?RC_SUCCESS]}, channel()).

t_handle_out_disconnect(_) ->
    Packet = ?DISCONNECT_PACKET(?RC_SUCCESS),
    {ok, [{outgoing, Packet}, {close, normal}], _Chan} =
        emqx_channel:handle_out(disconnect, ?RC_SUCCESS, channel()).

t_handle_out_unexpected(_) ->
    {ok, _Channel} = emqx_channel:handle_out(unexpected, <<"data">>, channel()).

%%--------------------------------------------------------------------
%% Test cases for handle_call
%%--------------------------------------------------------------------

t_handle_call_kick(_) ->
    {shutdown, kicked, ok, _Chan} = emqx_channel:handle_call(kick, channel()).

t_handle_call_discard(_) ->
    Packet = ?DISCONNECT_PACKET(?RC_SESSION_TAKEN_OVER),
    {shutdown, discarded, ok, Packet, _Channel} =
        emqx_channel:handle_call(discard, channel()).

t_handle_call_takeover_begin(_) ->
    {reply, _Session, _Chan} = emqx_channel:handle_call({takeover, 'begin'}, channel()).

t_handle_call_takeover_end(_) ->
    ok = meck:expect(emqx_session, takeover, fun(_) -> ok end),
    {shutdown, takeovered, [], _, _Chan} =
        emqx_channel:handle_call({takeover, 'end'}, channel()).

t_handle_call_quota(_) ->
    {reply, ok, _Chan} = emqx_channel:handle_call(
                           {quota, [{conn_messages_routing, {100,1}}]},
                           channel()
                         ).

t_handle_call_unexpected(_) ->
    {reply, ignored, _Chan} = emqx_channel:handle_call(unexpected_req, channel()).

%%--------------------------------------------------------------------
%% Test cases for handle_info
%%--------------------------------------------------------------------

t_handle_info_subscribe(_) ->
    ok = meck:expect(emqx_session, subscribe, fun(_, _, _, Session) -> {ok, Session} end),
    {ok, _Chan} = emqx_channel:handle_info({subscribe, topic_filters()}, channel()).

t_handle_info_unsubscribe(_) ->
    ok = meck:expect(emqx_session, unsubscribe, fun(_, _, _, Session) -> {ok, Session} end),
    {ok, _Chan} = emqx_channel:handle_info({unsubscribe, topic_filters()}, channel()).

t_handle_info_sock_closed(_) ->
    Channel = channel(#{conn_state => disconnected}),
    {ok, Channel} = emqx_channel:handle_info({sock_closed, reason}, Channel).

%%--------------------------------------------------------------------
%% Test cases for handle_timeout
%%--------------------------------------------------------------------

t_handle_timeout_emit_stats(_) ->
    TRef = make_ref(),
    ok = meck:expect(emqx_cm, set_chan_stats, fun(_, _) -> ok end),
    Channel = emqx_channel:set_field(timers, #{stats_timer => TRef}, channel()),
    {ok, _Chan} = emqx_channel:handle_timeout(TRef, {emit_stats, []}, Channel).

t_handle_timeout_keepalive(_) ->
    TRef = make_ref(),
    Channel = emqx_channel:set_field(timers, #{alive_timer => TRef}, channel()),
    {ok, _Chan} = emqx_channel:handle_timeout(make_ref(), {keepalive, 10}, Channel).

t_handle_timeout_retry_delivery(_) ->
    TRef = make_ref(),
    ok = meck:expect(emqx_session, retry, fun(_, Session) -> {ok, Session} end),
    Channel = emqx_channel:set_field(timers, #{retry_timer => TRef}, channel()),
    {ok, _Chan} = emqx_channel:handle_timeout(TRef, retry_delivery, Channel).

t_handle_timeout_expire_awaiting_rel(_) ->
    TRef = make_ref(),
    ok = meck:expect(emqx_session, expire, fun(_, Session) -> {ok, Session} end),
    Channel = emqx_channel:set_field(timers, #{await_timer => TRef}, channel()),
    {ok, _Chan} = emqx_channel:handle_timeout(TRef, expire_awaiting_rel, Channel).

t_handle_timeout_expire_session(_) ->
    TRef = make_ref(),
    Channel = emqx_channel:set_field(timers, #{expire_timer => TRef}, channel()),
    {shutdown, expired, _Chan} = emqx_channel:handle_timeout(TRef, expire_session, Channel).

t_handle_timeout_will_message(_) ->
    {ok, _Chan} = emqx_channel:handle_timeout(make_ref(), will_message, channel()).

%%--------------------------------------------------------------------
%% Test cases for internal functions
%%--------------------------------------------------------------------

t_enrich_conninfo(_) ->
    {ok, _Chan} = emqx_channel:enrich_conninfo(connpkt(), channel()).

t_enrich_client(_) ->
    {ok, _ConnPkt, _Chan} = emqx_channel:enrich_client(connpkt(), channel()).

t_check_banned(_) ->
    ok = emqx_channel:check_banned(connpkt(), channel()).

t_auth_connect(_) ->
    {ok, _Chan} = emqx_channel:auth_connect(connpkt(), channel()).

t_process_alias(_) ->
    Publish = #mqtt_packet_publish{topic_name = <<>>, properties = #{'Topic-Alias' => 1}},
    Channel = emqx_channel:set_field(topic_aliases, #{inbound => #{1 => <<"t">>}}, channel()),
    {ok, #mqtt_packet{variable = #mqtt_packet_publish{topic_name = <<"t">>}}, _Chan} =
        emqx_channel:process_alias(#mqtt_packet{variable = Publish}, Channel).

t_process_alias_inexistent_alias(_) ->
    Publish = #mqtt_packet_publish{topic_name = <<>>, properties = #{'Topic-Alias' => 1}},
    Channel = channel(),
    ?assertEqual(
      {error, ?RC_PROTOCOL_ERROR},
      emqx_channel:process_alias(#mqtt_packet{variable = Publish}, Channel)).

t_packing_alias(_) ->
    Packet1 = #mqtt_packet{variable = #mqtt_packet_publish{
                                         topic_name = <<"x">>,
                                         properties = #{'User-Property' => [{<<"k">>, <<"v">>}]}
                                        }},
    Packet2 = #mqtt_packet{variable = #mqtt_packet_publish{topic_name = <<"y">>}},
    Channel = emqx_channel:set_field(alias_maximum, #{outbound => 1}, channel()),

    {RePacket1, NChannel1} = emqx_channel:packing_alias(Packet1, Channel),
    ?assertEqual(#mqtt_packet{variable = #mqtt_packet_publish{
                                            topic_name = <<"x">>,
                                            properties = #{
                                                'Topic-Alias' => 1,
                                                'User-Property' => [{<<"k">>, <<"v">>}]
                                             }
                                           }}, RePacket1),

    {RePacket2, NChannel2} = emqx_channel:packing_alias(Packet1, NChannel1),
    ?assertEqual(#mqtt_packet{variable = #mqtt_packet_publish{
                                            topic_name = <<>>,
                                            properties = #{
                                                'Topic-Alias' => 1,
                                                'User-Property' => [{<<"k">>, <<"v">>}]
                                             }}}, RePacket2),

    {RePacket3, _} = emqx_channel:packing_alias(Packet2, NChannel2),
    ?assertEqual(
       #mqtt_packet{variable = #mqtt_packet_publish{topic_name = <<"y">>, properties = #{}}},
       RePacket3
    ),

    ?assertMatch({#mqtt_packet{variable = #mqtt_packet_publish{topic_name = <<"z">>}}, _},
                 emqx_channel:packing_alias(
                   #mqtt_packet{variable = #mqtt_packet_publish{topic_name = <<"z">>}},
                   channel())).

t_packing_alias_inexistent_alias(_) ->
    Publish = #mqtt_packet_publish{topic_name = <<>>, properties = #{'Topic-Alias' => 1}},
    Channel = channel(),
    Packet = #mqtt_packet{variable = Publish},
    ExpectedChannel = emqx_channel:set_field(
                        topic_aliases,
                        #{ inbound => #{}
                         , outbound => #{<<>> => 1}
                         },
                        Channel),
    ?assertEqual(
      {Packet, ExpectedChannel},
      emqx_channel:packing_alias(Packet, Channel)).

t_check_pub_acl(_) ->
    ok = meck:expect(emqx_zone, enable_acl, fun(_) -> true end),
    Publish = ?PUBLISH_PACKET(?QOS_0, <<"t">>, 1, <<"payload">>),
    ok = emqx_channel:check_pub_acl(Publish, channel()).

t_check_pub_alias(_) ->
    Publish = #mqtt_packet_publish{topic_name = <<>>, properties = #{'Topic-Alias' => 1}},
    Channel = emqx_channel:set_field(alias_maximum, #{inbound => 10}, channel()),
    ok = emqx_channel:check_pub_alias(#mqtt_packet{variable = Publish}, Channel).

t_check_sub_acls(_) ->
    ok = meck:expect(emqx_zone, enable_acl, fun(_) -> true end),
    TopicFilter = {<<"t">>, ?DEFAULT_SUBOPTS},
    [{TopicFilter, 0}] = emqx_channel:check_sub_acls([TopicFilter], channel()).

t_enrich_connack_caps(_) ->
    ok = meck:new(emqx_mqtt_caps, [passthrough, no_history]),
    ok = meck:expect(emqx_mqtt_caps, get_caps,
                     fun(_Zone) ->
                        #{max_packet_size => 1024,
                          max_qos_allowed => ?QOS_2,
                          retain_available => true,
                          max_topic_alias => 10,
                          shared_subscription => true,
                          wildcard_subscription => true
                         }
                     end),
    AckProps = emqx_channel:enrich_connack_caps(#{}, channel()),
    ?assertMatch(#{'Retain-Available' := 1,
                   'Maximum-Packet-Size' := 1024,
                   'Topic-Alias-Maximum' := 10,
                   'Wildcard-Subscription-Available' := 1,
                   'Subscription-Identifier-Available' := 1,
                   'Shared-Subscription-Available' := 1
                  }, AckProps),
    ok = meck:unload(emqx_mqtt_caps).

%%--------------------------------------------------------------------
%% Test cases for terminate
%%--------------------------------------------------------------------

t_terminate(_) ->
    ok = emqx_channel:terminate(normal, channel()),
    ok = emqx_channel:terminate(sock_error, channel(#{conn_state => connected})),
    ok = emqx_channel:terminate({shutdown, kicked}, channel(#{conn_state => connected})).

t_ws_cookie_init(_) ->
    WsCookie = [{<<"session_id">>, <<"xyz">>}],
    ConnInfo = #{socktype => ws,
                 peername => {{127,0,0,1}, 3456},
                 sockname => {{127,0,0,1}, 1883},
                 peercert => nossl,
                 conn_mod => emqx_ws_connection,
                 ws_cookie => WsCookie
                },
    Channel = emqx_channel:init(ConnInfo, [{zone, zone}]),
    ?assertMatch(#{ws_cookie := WsCookie}, emqx_channel:info(clientinfo, Channel)).

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

channel() -> channel(#{}).
channel(InitFields) ->
    ConnInfo = #{peername => {{127,0,0,1}, 3456},
                 sockname => {{127,0,0,1}, 1883},
                 conn_mod => emqx_connection,
                 proto_name => <<"MQTT">>,
                 proto_ver => ?MQTT_PROTO_V5,
                 clean_start => true,
                 keepalive => 30,
                 clientid => <<"clientid">>,
                 username => <<"username">>,
                 conn_props => #{},
                 receive_maximum => 100,
                 expiry_interval => 0
                },
    maps:fold(fun(Field, Value, Channel) ->
                      emqx_channel:set_field(Field, Value, Channel)
              end,
              emqx_channel:init(ConnInfo, [{zone, zone}]),
              maps:merge(#{clientinfo => clientinfo(),
                           session    => session(),
                           conn_state => connected
                          }, InitFields)).

clientinfo() -> clientinfo(#{}).
clientinfo(InitProps) ->
    maps:merge(#{zone       => zone,
                 protocol   => mqtt,
                 peerhost   => {127,0,0,1},
                 clientid   => <<"clientid">>,
                 username   => <<"username">>,
                 is_superuser => false,
                 peercert   => undefined,
                 mountpoint => undefined
                }, InitProps).

topic_filters() ->
    [{<<"+">>, ?DEFAULT_SUBOPTS}, {<<"#">>, ?DEFAULT_SUBOPTS}].

connpkt() -> connpkt(#{}).
connpkt(Props) ->
    #mqtt_packet_connect{
       proto_name  = <<"MQTT">>,
       proto_ver   = ?MQTT_PROTO_V4,
       is_bridge   = false,
       clean_start = true,
       keepalive   = 30,
       properties  = Props,
       clientid    = <<"clientid">>,
       username    = <<"username">>,
       password    = <<"passwd">>
      }.

session() -> session(#{}).
session(InitFields) when is_map(InitFields) ->
    maps:fold(fun(Field, Value, Session) ->
                      emqx_session:set_field(Field, Value, Session)
              end,
              emqx_session:init(#{zone => channel}, #{receive_maximum => 0}),
              InitFields).

%% conn: 5/s; overall: 10/s
quota() ->
    emqx_limiter:init(zone, [{conn_messages_routing, {5, 1}},
                             {overall_messages_routing, {10, 1}}]).
