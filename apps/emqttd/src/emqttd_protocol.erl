%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2015, Feng Lee <feng@emqtt.io>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% emqttd protocol.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(emqttd_protocol).

-include("emqttd.hrl").

-include("emqttd_packet.hrl").

%% API
-export([init/2, client_id/1]).

-export([received/2, send/2, redeliver/2, shutdown/2]).

-export([info/1]).

%% Protocol State
-record(proto_state, {
        transport,
        socket,
        peer_name,
        connected = false, %received CONNECT action?
        proto_ver,
        proto_name,
		%packet_id,
		client_id,
		clean_sess,
        session, %% session state or session pid
		will_msg,
        max_clientid_len = ?MAX_CLIENTID_LEN
}).

-type proto_state() :: #proto_state{}.

init({Transport, Socket, Peername}, Opts) ->
	#proto_state{
        transport        = Transport,
		socket	         = Socket,
        peer_name        = Peername,
        max_clientid_len = proplists:get_value(max_clientid_len, Opts, ?MAX_CLIENTID_LEN)}. 

client_id(#proto_state{client_id = ClientId}) -> ClientId.

%%SHOULD be registered in emqttd_cm
info(#proto_state{proto_ver    = ProtoVer,
                  proto_name   = ProtoName,
				  client_id	   = ClientId,
				  clean_sess   = CleanSess,
				  will_msg	   = WillMsg}) ->
	[{proto_ver,  ProtoVer},
     {proto_name, ProtoName},
	 {client_id,  ClientId},
	 {clean_sess, CleanSess},
	 {will_msg,   WillMsg}].

%%CONNECT – Client requests a connection to a Server

%%A Client can only send the CONNECT Packet once over a Network Connection. 
-spec received(mqtt_packet(), proto_state()) -> {ok, proto_state()} | {error, any()}. 
received(Packet = ?PACKET(?CONNECT), State = #proto_state{connected = false}) ->
    handle(Packet, State#proto_state{connected = true});

received(?PACKET(?CONNECT), State = #proto_state{connected = true}) ->
    {error, protocol_bad_connect, State};

%%Received other packets when CONNECT not arrived.
received(_Packet, State = #proto_state{connected = false}) ->
    {error, protocol_not_connected, State};

received(Packet = ?PACKET(_Type), State = #proto_state{peer_name = PeerName,
                                                       client_id = ClientId}) ->
	lager:debug("RECV from ~s@~s: ~s", [ClientId, PeerName, emqttd_packet:dump(Packet)]),
	case validate_packet(Packet) of	
	ok ->
		handle(Packet, State);
	{error, Reason} ->
		{error, Reason, State}
	end.

handle(Packet = ?CONNECT_PACKET(Var), State = #proto_state{peer_name = PeerName}) ->

    #mqtt_packet_connect{proto_ver  = ProtoVer,
                         username   = Username,
                         password   = Password,
                         clean_sess = CleanSess,
                         keep_alive = KeepAlive,
                         client_id  = ClientId} = Var,

    lager:debug("RECV from ~s@~s: ~s", [ClientId, PeerName, emqttd_packet:dump(Packet)]),

    {ReturnCode1, State1} =
    case validate_connect(Var, State) of
        ?CONNACK_ACCEPT ->
            case emqttd_auth:check(Username, Password) of
                true ->
                    ClientId1 = clientid(ClientId, State), 
                    start_keepalive(KeepAlive),
                    emqttd_cm:register(ClientId1, self()),
                    {?CONNACK_ACCEPT, State#proto_state{proto_ver  = ProtoVer,
                                                        client_id  = ClientId1,
                                                        clean_sess = CleanSess,
                                                        will_msg   = willmsg(Var)}};
                false ->
                    lager:error("~s@~s: username '~s' login failed - no credentials", [ClientId, PeerName, Username]),
                    {?CONNACK_CREDENTIALS, State#proto_state{client_id = ClientId}}
            end;
        ReturnCode ->
            {ReturnCode, State#proto_state{client_id = ClientId,
                                           clean_sess = CleanSess}}
    end,
    notify(connected, ReturnCode1, State1),
    send(?CONNACK_PACKET(ReturnCode1), State1),
    %%Starting session
    {ok, Session} = emqttd_session:start({CleanSess, ClientId, self()}),
    {ok, State1#proto_state{session = Session}};

handle(Packet = ?PUBLISH_PACKET(?QOS_0, _Topic, _PacketId, _Payload),
       State = #proto_state{session = Session}) ->
    emqttd_session:publish(Session, {?QOS_0, emqttd_message:from_packet(Packet)}),
	{ok, State};

handle(Packet = ?PUBLISH_PACKET(?QOS_1, _Topic, PacketId, _Payload),
         State = #proto_state{session = Session}) ->
    emqttd_session:publish(Session, {?QOS_1, emqttd_message:from_packet(Packet)}),
    send(?PUBACK_PACKET(?PUBACK, PacketId), State);

handle(Packet = ?PUBLISH_PACKET(?QOS_2, _Topic, PacketId, _Payload),
         State = #proto_state{session = Session}) ->
    NewSession = emqttd_session:publish(Session, {?QOS_2, emqttd_message:from_packet(Packet)}),
	send(?PUBACK_PACKET(?PUBREC, PacketId), State#proto_state{session = NewSession});

handle(?PUBACK_PACKET(Type, PacketId), State = #proto_state{session = Session}) 
    when Type >= ?PUBACK andalso Type =< ?PUBCOMP ->
    NewSession = emqttd_session:puback(Session, {Type, PacketId}),
    NewState = State#proto_state{session = NewSession},
    if 
        Type =:= ?PUBREC ->
            send(?PUBREL_PACKET(PacketId), NewState);
        Type =:= ?PUBREL ->
            send(?PUBACK_PACKET(?PUBCOMP, PacketId), NewState);
        true ->
            ok
    end,
	{ok, NewState};

handle(?SUBSCRIBE_PACKET(PacketId, TopicTable), State = #proto_state{session = Session}) ->
    {ok, NewSession, GrantedQos} = emqttd_session:subscribe(Session, TopicTable),
    send(?SUBACK_PACKET(PacketId, GrantedQos), State#proto_state{session = NewSession});

handle(?UNSUBSCRIBE_PACKET(PacketId, Topics), State = #proto_state{session = Session}) ->
    {ok, NewSession} = emqttd_session:unsubscribe(Session, Topics),
    send(?UNSUBACK_PACKET(PacketId), State#proto_state{session = NewSession});

handle(?PACKET(?PINGREQ), State) ->
    send(?PACKET(?PINGRESP), State);

handle(?PACKET(?DISCONNECT), State) ->
    %%TODO: how to handle session?
    % clean willmsg
    {stop, normal, State#proto_state{will_msg = undefined}}.

-spec send({pid() | tuple(), mqtt_message()} | mqtt_packet(), proto_state()) -> {ok, proto_state()}.
%% qos0 message
send({_From, Message = #mqtt_message{qos = ?QOS_0}}, State) ->
	send(emqttd_message:to_packet(Message), State);

%% message from session
send({_From = SessPid, Message}, State = #proto_state{session = SessPid}) when is_pid(SessPid) ->
	send(emqttd_message:to_packet(Message), State);

%% message(qos1, qos2) not from session
send({_From, Message = #mqtt_message{qos = Qos}}, State = #proto_state{session = Session}) 
    when (Qos =:= ?QOS_1) orelse (Qos =:= ?QOS_2) ->
    {Message1, NewSession} = emqttd_session:store(Session, Message),
	send(emqttd_message:to_packet(Message1), State#proto_state{session = NewSession});

send(Packet, State = #proto_state{transport = Transport, socket = Sock, peer_name = PeerName, client_id = ClientId}) when is_record(Packet, mqtt_packet) ->
	lager:debug("SENT to ~s@~s: ~s", [ClientId, PeerName, emqttd_packet:dump(Packet)]),
    sent_stats(Packet),
    Data = emqttd_serialiser:serialise(Packet),
    lager:debug("SENT to ~s: ~p", [PeerName, Data]),
    emqttd_metrics:inc('bytes/sent', size(Data)),
    Transport:send(Sock, Data),
    {ok, State}.

%%
%% @doc redeliver PUBREL PacketId
%%
redeliver({?PUBREL, PacketId}, State) ->
    send(?PUBREL_PACKET(PacketId), State).

shutdown(Error, #proto_state{peer_name = PeerName, client_id = ClientId, will_msg = WillMsg}) ->
    send_willmsg(WillMsg),
    try_unregister(ClientId, self()),
	lager:debug("Protocol ~s@~s Shutdown: ~p", [ClientId, PeerName, Error]),
    ok.

willmsg(Packet) when is_record(Packet, mqtt_packet_connect) ->
    emqttd_message:from_packet(Packet).

clientid(<<>>, #proto_state{peer_name = PeerName}) ->
    <<"eMQTT/", (base64:encode(PeerName))/binary>>;

clientid(ClientId, _State) -> ClientId.

%%----------------------------------------------------------------------------

send_willmsg(undefined) -> ignore;
%%TODO:should call session...
send_willmsg(WillMsg) -> emqttd_router:route(WillMsg).

start_keepalive(0) -> ignore;
start_keepalive(Sec) when Sec > 0 ->
    self() ! {keepalive, start, round(Sec * 1.5)}.

%%----------------------------------------------------------------------------
%% Validate Packets
%%----------------------------------------------------------------------------
validate_connect(Connect = #mqtt_packet_connect{}, ProtoState) ->
    case validate_protocol(Connect) of
        true -> 
            case validate_clientid(Connect, ProtoState) of
                true -> 
                    ?CONNACK_ACCEPT;
                false -> 
                    ?CONNACK_INVALID_ID
            end;
        false -> 
            ?CONNACK_PROTO_VER
    end.

validate_protocol(#mqtt_packet_connect{proto_ver = Ver, proto_name = Name}) ->
    lists:member({Ver, Name}, ?PROTOCOL_NAMES).

validate_clientid(#mqtt_packet_connect{client_id = ClientId}, #proto_state{max_clientid_len = MaxLen})
    when ( size(ClientId) >= 1 ) andalso ( size(ClientId) =< MaxLen ) ->
    true;

%% MQTT3.1.1 allow null clientId.
validate_clientid(#mqtt_packet_connect{proto_ver =?MQTT_PROTO_V311, client_id = ClientId}, _ProtoState) 
    when size(ClientId) =:= 0 ->
    true;

validate_clientid(#mqtt_packet_connect {proto_ver = Ver, clean_sess = CleanSess, client_id = ClientId}, _ProtoState) -> 
    lager:warning("Invalid ClientId: ~s, ProtoVer: ~p, CleanSess: ~s", [ClientId, Ver, CleanSess]),
    false.

validate_packet(#mqtt_packet{header  = #mqtt_packet_header{type = ?PUBLISH}, 
                             variable = #mqtt_packet_publish{topic_name = Topic}}) ->
	case emqttd_topic:validate({name, Topic}) of
	true -> ok;
	false -> lager:warning("Error publish topic: ~p", [Topic]), {error, badtopic}
	end;

validate_packet(#mqtt_packet{header  = #mqtt_packet_header{type = ?SUBSCRIBE},
                             variable = #mqtt_packet_subscribe{topic_table = Topics}}) ->

    validate_topics(filter, Topics);

validate_packet(#mqtt_packet{ header  = #mqtt_packet_header{type = ?UNSUBSCRIBE}, 
                              variable = #mqtt_packet_subscribe{topic_table = Topics}}) ->

    validate_topics(filter, Topics);

validate_packet(_Packet) -> 
    ok.

validate_topics(Type, []) when Type =:= name orelse Type =:= filter ->
	lager:error("Empty Topics!"),
    {error, empty_topics};

validate_topics(Type, Topics) when Type =:= name orelse Type =:= filter ->
	ErrTopics = [Topic || {Topic, Qos} <- Topics,
						not (emqttd_topic:validate({Type, Topic}) and validate_qos(Qos))],
	case ErrTopics of
	[] -> ok;
	_ -> lager:error("Error Topics: ~p", [ErrTopics]), {error, badtopic}
	end.

validate_qos(undefined) -> true;
validate_qos(Qos) when Qos =< ?QOS_2 -> true;
validate_qos(_) -> false.

try_unregister(undefined, _) -> ok;
try_unregister(ClientId, _) -> emqttd_cm:unregister(ClientId, self()).

sent_stats(?PACKET(Type)) ->
    emqttd_metrics:inc('packets/sent'), 
    inc(Type).
inc(?CONNACK) ->
    emqttd_metrics:inc('packets/connack');
inc(?PUBLISH) ->
    emqttd_metrics:inc('messages/sent'),
    emqttd_metrics:inc('packets/publish/sent');
inc(?SUBACK) ->
    emqttd_metrics:inc('packets/suback');
inc(?UNSUBACK) ->
    emqttd_metrics:inc('packets/unsuback');
inc(?PINGRESP) ->
    emqttd_metrics:inc('packets/pingresp');
inc(_) ->
    ingore.

notify(connected, ReturnCode, #proto_state{peer_name = PeerName, 
                                           proto_ver  = ProtoVer, 
                                           client_id  = ClientId, 
                                           clean_sess = CleanSess}) ->
    Sess = case CleanSess of
        true -> false;
        false -> true
    end,
    Params = [{from, PeerName},
              {protocol, ProtoVer},
              {session, Sess},
              {connack, ReturnCode}],
    emqttd_event:notify({connected, ClientId, Params}).


