%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at lordnull dot com>
%%

%% @doc A gen_fsm representing the agent's state.  When idle, channels are
%% available to ring.  When released, channels are not.
-module(agent).
-behaviour(gen_fsm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include("call.hrl").
-include("agent.hrl").
-include_lib("stdlib/include/qlc.hrl").

-type(agent_opt() :: {'nodes', [atom()]} | 'logging').
-type(agent_opts() :: [agent_opt()]).

%% slow text is textual medias that do not requrie a particually fast 
%% response, such as email.  Fast_text is textual medias that require rapid
%% replies, such as chat.
%-type(channel_category() :: 'dummy' | 'voice' | 'visual' | 'slow_text' | 'fast_text').
-record(state, {
	agent_rec :: #agent{}
}).

-type(state() :: #state{}).
-define(GEN_FSM, true).
-include("gen_spec.hrl").

-define(default_category_blocks, [
	{dummy, none},
	{voice, all},
	{visual, all},
	{slow_text, self},
	{fast_text, others}
]).

%% gen_fsm exports
-export([
	init/1,
	handle_event/3,
	handle_sync_event/4,
	handle_info/3,
	terminate/3,
	code_change/4%,
	%format_status/2
]).
%% defined state exports
-export([
	idle/3,
	released/3
]).
%% defining async state exports
-export([
	idle/2,
	released/2
]).

%% other exports
-export([
	%start/1,
	start/2,
	%start_link/1,
	start_link/2,
	stop/1,
	set_release/2,
	add_skills/2,
	remove_skills/2,
	change_profile/2,
	query_state/1, 
	dump_state/1, 
	register_rejected/1,
	log_loop/4,
	set_connection/2,
	set_endpoint/3,
	set_endpoints/2,
	get_endpoint/2,
	blab/2]).

%% Channel Starters
-export([
	precall/3,
	prering/2,
	ringing/2
]).

% ======================================================================
% API
% ======================================================================

%% @doc Start an agent fsm for the passed in agent record `Agent' that is linked
%% to the calling process with the given options.
-spec(start_link/2 :: (Agent :: #agent{}, Options :: agent_opts()) -> {'ok', pid()}).
start_link(Agent, Options) when is_record(Agent, agent) ->
	gen_fsm:start_link(?MODULE, [Agent, Options], []).

%% @doc Start an agent fsm for the passed in agent record `Agent' with the given
%% options.
-spec(start/2 :: (Agent :: #agent{}, Options :: agent_opts()) -> {'ok', pid()}).
start(Agent, Options) when is_record(Agent, agent) ->
	gen_fsm:start(?MODULE, [Agent, Options], []).

%% @doc Stop the passed agent fsm `Pid'.
-spec(stop/1 :: (Pid :: pid()) -> 'ok').
stop(Pid) -> 
	gen_fsm:send_all_state_event(Pid, stop).

%% @doc Set the agent released or idle.
-spec(set_release/2 :: (Pid :: pid(), Released :: 'none' | 'default' | release_code()) -> 'ok').
set_release(Pid, Released) ->
	gen_fsm:sync_send_event(Pid, {set_release, Released}).

%% @doc link the given agent  `Pid' to the given connection `Socket'.
-spec(set_connection/2 :: (Pid :: pid(), Socket :: pid()) -> 'ok' | 'error').
set_connection(Pid, Socket) ->
	gen_fsm:sync_send_all_state_event(Pid, {set_connection, Socket}).

%% @doc When the agent manager can't register an agent, it 'casts' to this.
-spec(register_rejected/1 :: (Pid :: pid()) -> 'ok').
register_rejected(Pid) ->
	gen_fsm:send_event(Pid, register_rejected).

%% @doc When the media wants to cast to the connnection.
%-spec(conn_cast/2 :: (Apid :: pid(), Request :: any()) -> 'ok').
%conn_cast(Apid, Request) ->
%	gen_fsm:send_event(Apid, {conn_cast, Request}).

%% @doc When the media wants to call to the connection.
%-spec(conn_call/2 :: (Apid :: pid(), Request :: any()) -> any()).
%conn_call(Apid, Request) ->
%	gen_fsm:sync_send_event(Apid, {conn_call, Request}).
%	
%% @doc The connection can request to call to the agent's media when oncall.
%-spec(media_call/2 :: (Apid :: pid(), Request :: any()) -> any()).
%media_call(Apid, Request) ->
%	gen_fsm:sync_send_event(Apid, {mediacall, Request}).

%% @doc To cast to the media while oncall, use this.
%-spec(media_cast/2 :: (Apid :: pid(), Request :: any()) -> 'ok').
%media_cast(Apid, Request) ->
%	gen_fsm:send_event(Apid, {mediacast, Request}).

% actual functions we'll call
%% @private
-spec(expand_magic_skills/2 :: (State :: #agent{}, Skills :: [atom()]) -> [atom()]).
expand_magic_skills(State, Skills) ->
	lists:map(
		fun('_agent') -> {'_agent', State#agent.login};
		('_node') -> {'_node', node()};
		('_profile') -> {'_profile', State#agent.profile};
		(Skill) -> Skill
	end, Skills).

%% @doc Returns the entire agent record for the agent at `Pid'.
-spec(dump_state/1 :: (Pid :: pid()) -> #agent{}).
dump_state(Pid) ->
	gen_fsm:sync_send_all_state_event(Pid, dump_state).

%% @doc Returns the #call{} of the current state if there is on, otherwise 
%% returns `invalid'.
%-spec(get_media/1 :: (Apid :: pid()) -> {ok, #call{}} | 'invalid').
%get_media(Apid) ->
%	gen_fsm:sync_send_event(Apid, get_media).

-spec(add_skills/2 :: (Apid :: pid(), Skills :: [atom() | {atom(), any()}]) -> 'ok').
add_skills(Apid, Skills) when is_list(Skills), is_pid(Apid) ->
	gen_fsm:sync_send_all_state_event(Apid, {add_skills, Skills}).

-spec(remove_skills/2 :: (Apid :: pid(), Skills :: [atom() | {atom(), any()}]) -> 'ok').
remove_skills(Apid, Skills) when is_list(Skills), is_pid(Apid) ->
	gen_fsm:sync_send_all_state_event(Apid, {remove_skills, Skills}).

-spec(change_profile/2 :: (Apid :: pid(), Profile :: string()) -> 'ok' | {'error', 'unknown_profile'}).
change_profile(Apid, Profile) ->
	gen_fsm:sync_send_all_state_event(Apid, {change_profile, Profile}).

%% @doc Returns `{ok, Statename :: atom()}', where `Statename' is the current state of the agent at `Pid'.
-spec(query_state/1 :: (Pid :: pid()) -> {'ok', atom()}).
query_state(Pid) -> 
	gen_fsm:sync_send_all_state_event(Pid, query_state).

%% @doc Attempt to set the state of agent at `Pid' to `State'.
%-spec(set_state/2 :: (Pid :: pid(), State :: atom()) -> 'ok' | 'invalid').
%set_state(Pid, State) ->
%	gen_fsm:sync_send_event(Pid, State, infinity).

%% @doc Attempt to set the state of the agent at `Pid' to `State' with data `Data'.  `Data' is related to the `State' the agent is going into.  
%% Often `Data' will be `#call{} or a callid of type `string()'.
%-spec(set_state/3 :: (Pid :: pid(), State :: 'idle' | 'ringing' | 'precall' | 'oncall' | 'outgoing' | 'warmtransfer' | 'wrapup', Data :: any()) -> 'ok' | 'invalid';
%                     (Pid :: pid(), State :: 'released', Data :: any()) -> 'ok' | 'invalid' | 'queued').
%set_state(Pid, State, Data) ->
%	gen_fsm:sync_send_event(Pid, {State, Data}, infinity).

%% @doc attmept to push data from the media connection to the agent.  It's up to
%% the agent connection to interpret this correctly.
%-spec(media_push/2 :: (Pid :: pid(), Data :: any()) -> any()).
%media_push(Pid, Data) ->
%	S = self(),
%	gen_fsm:send_event(Pid, {mediapush, S, Data}).

%-spec(url_pop/3 :: (Pid :: pid(), Data :: list(), Name :: string()) -> any()).
%url_pop(Pid, Data, Name) ->
%	gen_fsm:sync_send_all_state_event(Pid, {url_pop, Data, Name}).

%% @doc Send a message to the human agent.  If there's no connection, it black-holes.
-spec(blab/2 :: (Pid :: pid(), Text :: string()) -> 'ok').
blab(Pid, Text) ->
	gen_fsm:send_all_state_event(Pid, {blab, Text}).

%% @doc Make the give `pid() Spy' spy on `pid() Target'.
%-spec(spy/2 :: (Spy :: pid(), Target :: pid()) -> 'ok' | 'invalid').
%spy(Spy, Target) ->
%	gen_fsm:sync_send_event(Spy, {spy, Target}).

%% @doc Get the endpoint for a given module from the agent record.
-spec(get_endpoint/2 :: (Module :: atom(), Agent :: #agent{}) -> {'ok', any()} | 'inband' | {'error', any()}).
get_endpoint(Module, Agent) when is_record(Agent, agent) ->
	get_endpoint(Module, Agent#agent.endpoints);
get_endpoint(Module, Ends) ->
	case dict:find(Module, Ends) of
		error -> {error, notfound};
		{ok, inband} -> inband;
		{ok, {module, NewMod}} -> get_endpoint(NewMod, Ends);
		{ok, Data} -> Data
	end.

%% @doc Set the endpoint data for a specific module.  The calling process is
%% forced to do much of the verification that the module mentioned exists
%% and implements the gen_media behaviour.  Data can be 'inband', 
%% {'module', atom()}, or arbitary data.
-spec(set_endpoint/3 :: (Agent :: pid(), Module :: atom(), Data :: any()) ->
'ok' | {'error', any()}).
set_endpoint(Agent, Module, Data) when is_pid(Agent), is_atom(Module) ->
	case proplists:get_value(Module, code:all_loaded()) of
		undefined ->
			{error, module_noexists};
		_ ->
			case proplists:get_value(behaviour, Module:module_info(attributes)) of
				[gen_media] ->
					gen_fsm:sync_send_all_state_event(Agent, {set_endpoint, Module, Data});
				_ ->
					{error, badmodule}
			end
	end.

%% @doc Set multiple endpoints for an agent.
-spec(set_endpoints/2 :: (Agent :: pid(), Endpoints :: [{atom(), any()}]) -> 'ok').
set_endpoints(Agent, Endpoints) when is_pid(Agent) ->
	NewEndpoints = filter_endpoints(Endpoints),
	gen_fsm:send_all_state_event(Agent, {set_endpoints, NewEndpoints}).

precall(Apid, Client, Type) ->
	gen_fsm:sync_send_event(Apid, {precall, Client, Type}).

prering(Apid, Data) ->
	gen_fsm:sync_send_event(Apid, {prering, Data}).

ringing(Apid, Call) ->
	gen_fsm:sync_send_event(Apid, {ringing, Call}).

% ======================================================================
% INIT
% ======================================================================

%% @private
%-spec(init/1 :: (Args :: [#agent{}]) -> {'ok', 'released', #agent{}}).
init([Agent, Options]) when is_record(Agent, agent) ->
	process_flag(trap_exit, true),
	#agent_profile{name = Profile, skills = Skills} = try agent_auth:get_profile(Agent#agent.profile) of
		undefined ->
			?WARNING("Agent ~p has an invalid profile of ~p, using Default", [Agent#agent.login, Agent#agent.profile]),
			agent_auth:get_profile("Default");
		Else ->
			Else
	catch
		error:{case_clause, {aborted, _}} ->
			#agent_profile{name = error}
	end,
	Agent2 = Agent#agent{skills = util:merge_skill_lists(expand_magic_skills(Agent, Skills), expand_magic_skills(Agent, Agent#agent.skills), ['_queue', '_brand']), profile = Profile},
	agent_manager:update_skill_list(Agent2#agent.login, Agent2#agent.skills),
	StateName = case Agent#agent.release_data of
		none ->
			gen_server:cast(dispatch_manager, {now_avail, self(), Agent2#agent.available_channels}),
			idle;
		_Other ->
			gen_server:cast(dispatch_manager, {end_avail, self()}),
			released
	end,
%	Agent3 = case proplists:get_value(logging, Options) of
%		true ->
%			Nodes = case proplists:get_value(nodes, Options) of
%				undefined ->
%					case application:get_env('OpenACD', nodes) of
%						{ok, N} -> N;
%						undefined -> [node()]
%					end;
%				Orelse -> Orelse
%			end,
%			Pid = spawn_link(agent, log_loop, [Agent#agent.id, Agent#agent.login, Nodes, Agent#agent.profile]),
%			Pid ! {Agent#agent.login, login, Agent#agent.state, Agent#agent.statedata},
%			Agent2#agent{log_pid = Pid};
%		_Orelse ->
%			Agent2
%	end,
	%set_cpx_monitor(Agent3, [{reason, default}, {bias, -1}], self()),
	{ok, StateName, #state{agent_rec = Agent}}.

% ======================================================================
% IDLE
% ======================================================================

idle({set_release, none}, _From, State) ->
	{reply, ok, idle, State};

idle({set_release, default}, From, State) ->
	idle({set_release, ?DEFAULT_RELEASE}, From, State);

idle({set_release, {Id, Reason, Bias} = Release}, _From, #state{agent_rec = Agent} = State) when Bias =< 1; Bias >= -1 ->
	gen_server:cast(dispatch_manager, {end_avail, self()}),
	gen_leader:cast(agent_manager, {set_avail, Agent#agent.login, []}),
	Now = util:now(),
	NewAgent = Agent#agent{release_data = Release, last_change = Now},
	inform_connection(Agent, {set_release, Release, Now}),
	set_cpx_monitor(NewAgent, [{released, true}, {reason, Reason}, {bias, Bias}, {reason_id, Id}]),
	{reply, ok, released, State#state{agent_rec = NewAgent}};

idle({precall, Call}, _From, #state{agent_rec = Agent} = State) ->
	case start_channel(Agent, Call, precall) of
		{ok, Pid, NewAgent} ->
			inform_connection(Agent, {new_channel, Pid, precall, Call}),
			{reply, {ok, Pid}, idle, State#state{agent_rec = NewAgent}};
		Else ->
			{reply, Else, idle, State}
	end;

idle({prering, Call}, _From, #state{agent_rec = Agent} = State) ->
	case start_channel(Agent, Call, prering) of
		{ok, Pid, NewAgent} ->
			inform_connection(Agent, {new_channel, Pid, prering, Call}),
			{reply, {ok, Pid}, idle, State#state{agent_rec = NewAgent}};
		Else ->
			{reply, Else, idle, State}
	end;

idle({ringing, Call}, _From, #state{agent_rec = Agent} = State) ->
	case start_channel(Agent, Call, prering) of
		{ok, Pid, NewAgent} ->
			inform_connection(Agent, {new_channel, Pid, ringing, Call}),
			{reply, {ok, Pid}, idle, State#state{agent_rec = NewAgent}};
		Else ->
			{reply, Else, idle, State}
	end;

idle(Msg, _From, State) ->
	{reply, {invalid, Msg}, idle, State}.

idle(Msg, State) ->
	{next_state, idle, State}.

% ======================================================================
% RELEASED
% ======================================================================

released({set_release, none}, _From, #state{agent_rec = Agent} = State) ->
	gen_server:cast(dispatch_manager, {now_avail, self(), Agent#agent.available_channels}),
	gen_leader:cast(agent_manager, {set_avail, Agent#agent.login, Agent#agent.available_channels}),
	Now = util:now(),
	NewAgent = Agent#agent{release_data = undefined, last_change = Now},
	set_cpx_monitor(NewAgent, [{released, false}]),
	inform_connection(Agent, {set_release, none, Now}),
	{reply, ok, idle, State#state{agent_rec = NewAgent}};

released({set_release, {Id, Label, Bias} = Release}, _From, #state{agent_rec = Agent} = State) ->
	Now = util:now(),
	NewAgent = Agent#agent{release_data = Release, last_change = Now},
	inform_connection(Agent, {set_release, Release, Now}),
	set_cpx_monitor(NewAgent, [{released, true}, {reason, Label}, {bias, Bias}, {reason_id, Id}]),
	{reply, ok, released, State#state{agent_rec = NewAgent}};

released(Msg, _From, State) ->
	{reply, {error, Msg}, released, State}.

released(Msg, State) ->
	{next_state, released, State}.
	
% ======================================================================
% HANDLE_SYNC_EVENT
% ======================================================================

handle_sync_event({set_connection, Pid}, _From, StateName, #state{agent_rec = #agent{connection = undefined} = Agent} = State) ->
	link(Pid),
	dict:map(fun(ChanPid, V) ->
		agent_channel:set_connection(ChanPid, Pid),
		V
	end, Agent#agent.used_channels),
	case erlang:function_exported(cpx_supervisor, get_value, 1) of
		true ->
			case cpx_supervisor:get_value(motd) of
				{ok, Motd} ->
					gen_server:cast(Pid, {blab, Motd});
				_ ->
					ok
			end;
		false ->
			ok
	end,
	Newagent = Agent#agent{connection = Pid},
	inform_connection(Agent, {set_release, Agent#agent.release_data}),
	{reply, ok, StateName, State#state{agent_rec = Newagent}};

handle_sync_event(dump_state, _From, StateName, #state{agent_rec = Agent} = State) ->
	{reply, Agent, StateName, State};

handle_sync_event({set_connection, _Pid}, _From, StateName, #state{agent_rec = Agent} = State) ->
	?WARNING("An attempt to set connection to ~w when there is already a connection ~w", [_Pid, Agent#agent.connection]),
	{reply, error, StateName, State};

handle_sync_event({change_profile, Profile}, _From, StateName, #state{agent_rec = Agent} = State) ->
	OldProfile = Agent#agent.profile,
	OldSkills = case agent_auth:get_profile(OldProfile) of
		#agent_profile{skills = Skills} ->
			Skills;
		_ ->
			[]
	end,
	case agent_auth:get_profile(Profile) of
		#agent_profile{name = Profile, skills = Skills2} ->
			NewAgentSkills = util:subtract_skill_lists(Agent#agent.skills, expand_magic_skills(Agent, OldSkills)),
			NewAgentSkills2 = util:merge_skill_lists(NewAgentSkills, expand_magic_skills(Agent#agent{profile = Profile}, Skills2), ['_queue', '_brand']),
			Newagent = Agent#agent{skills = NewAgentSkills2, profile = Profile},
			Deatils = [
				{profile, Newagent#agent.profile}, 
				{login, Newagent#agent.login}, 
				{skills, Newagent#agent.skills}
			],
			gen_server:cast(Agent#agent.connection, {change_profile, Profile}),
			Agent#agent.log_pid ! {change_profile, Profile, StateName},
			cpx_monitor:set({agent, Agent#agent.id}, Deatils),
			inform_connection(Agent, {change_profile, Profile}),
			inform_connection(Agent, {set_release, Agent#agent.release_data, Agent#agent.last_change}),
			DroppedSkills = OldSkills -- NewAgentSkills2,
			GainedSkills = NewAgentSkills2 -- OldSkills,
			ProfChangeRec = #agent_profile_change{
				id = Agent#agent.id,
				agent = Agent#agent.login,
				old_profile = OldProfile,
				new_profile = Profile,
				skills = NewAgentSkills2,
				dropped_skills = DroppedSkills,
				gained_skills = GainedSkills
			},
			cpx_monitor:info({agent_profile, ProfChangeRec}),
			{reply, ok, StateName, State#state{agent_rec = Newagent}};
		_ ->
			{reply, {error, unknown_profile}, StateName, State}
	end;

handle_sync_event({set_endpoint, Module, Data}, _From, StateName, #state{agent_rec = Agent} = State) ->
	case priv_set_endpoint(Agent, Module, Data) of
		{ok, NewAgent} ->
			gen_leader:cast(agent_manager, {set_ends, Agent#agent.login, dict:fetch_keys(NewAgent#agent.endpoints)}),
			{reply, ok, StateName, State#state{agent_rec = NewAgent}};
		{error, Err} = Error ->
			{reply, Error, StateName, State}
	end;
	
handle_sync_event(Msg, _From, StateName, State) ->
	{reply, {error, Msg}, StateName, State}.

% ======================================================================
% HANDLE_EVENT
% ======================================================================

handle_event({blab, Text}, Statename, #state{agent_rec = Agent} = State) ->
	?DEBUG("sending blab ~p", [Text]),
	inform_connection(Agent, {blab, Text}),
	{next_state, Statename, State};

handle_event(stop, _StateName, State) -> 
	{stop, normal, State};

handle_event({add_skills, Skills}, StateName, #state{agent_rec = Agent} = State) ->
	NewSkills = util:merge_skill_lists(expand_magic_skills(Agent, Skills), Agent#agent.skills, ['_queue', '_brand']),
	agent_manager:update_skill_list(Agent#agent.login, NewSkills),
	Newagent = Agent#agent{skills = NewSkills},
	{next_state, StateName, State#state{agent_rec = Newagent}};

handle_event({remove_skills, Skills}, StateName, #state{agent_rec = Agent} = State) ->
	NewSkills = util:subtract_skill_lists(Agent#agent.skills, expand_magic_skills(Agent, Skills)),
	agent_manager:update_skill_list(Agent#agent.login, NewSkills),
	Newagent = Agent#agent{skills = NewSkills},
	{next_state, StateName, State#state{agent_rec = Newagent}};

handle_event({set_endpoints, Ends}, StateName, State) ->
	NewAgent = priv_set_endpoints(State#state.agent_rec, Ends),
	gen_leader:cast(agent_manager, {set_ends, NewAgent#agent.login, dict:fetch_keys(NewAgent#agent.endpoints)}),
	{next_state, StateName, State};

handle_event(_Msg, StateName, State) ->
	{next_state, StateName, State}.

% ======================================================================
% HANDLE_INFO
% ======================================================================

handle_info({'EXIT', From, Reason}, StateName, #state{agent_rec = #agent{log_pid = From} = Agent} = State) ->
	?INFO("Log pid ~w died due to ~p", [From, Reason]),
	Nodes = case proplists:get_value(nodes, Agent#agent.start_opts) of
		undefined -> [node()];
		Else -> Else
	end,
	Pid = spawn_link(agent, log_loop, [Agent#agent.id, Agent#agent.login, Nodes, Agent#agent.profile]),
	Newagent = Agent#agent{log_pid = Pid},
	{next_state, StateName, State#state{agent_rec = Newagent}};

handle_info({'EXIT', From, Reason}, StateName, #state{agent_rec = #agent{connection = From} = _Agent} = State) ->
	?WARNING("agent connection died while ~w", [StateName]),
	Stopwhy = case Reason of
		normal ->
			normal;
		shutdown ->
			shutdown;
		Other ->
			{error, conn_exit, Other}
	end,
	{stop, Stopwhy, State};

handle_info({'EXIT', Pid, Reason}, StateName, #state{agent_rec = Agent} = State) ->
	case dict:find(Pid, Agent#agent.used_channels) of
		error ->
			case whereis(agent_manager) of
				undefined ->
					agent_manager_exit(Reason, StateName, State);
				From when is_pid(From) ->
					agent_manager_exit(Reason, StateName, State);
				_Else ->
					?INFO("unknown exit from ~p", [Pid]),
					{next_state, StateName, State}
			end;
		{ok, NowAvailChannels} ->
			% TODO This prolly isn't the best way to do it.
			?DEBUG("unblocking channels ~p", [NowAvailChannels]),
			NewAvail = lists:merge(Agent#agent.available_channels, NowAvailChannels),
			NewDict = dict:erase(Pid, Agent#agent.used_channels),
			NewAgent = Agent#agent{
				available_channels = NewAvail,
				used_channels = NewDict
			},
			case StateName of
				idle ->
					gen_server:cast(dispatch_manager, {now_avail, self(), NewAvail}),
					gen_leader:cast(agent_manager, {set_avail, Agent#agent.login, NowAvailChannels});
				_ ->
					ok
			end,
			inform_connection(Agent, {channel_died, Pid, NewAvail}),
			{next_state, StateName, State#state{agent_rec = NewAgent}}
	end.

% ======================================================================
% TERMINATE
% ======================================================================

%% @private
%-spec(terminate/3 :: (Reason :: any(), StateName :: statename(), State :: #state{}) -> 'ok').
terminate(Reason, StateName, #state{agent_rec = Agent} = _State) ->
	?NOTICE("Agent terminating:  ~p, State:  ~p", [Reason, StateName]),
	cpx_monitor:drop({agent, Agent#agent.id}),
	ok.

% ======================================================================
% CODE_CHANGE
% ======================================================================

%% @private
%-spec(code_change/4 :: (OldVsn :: string(), StateName :: statename(), State :: #state{}, Extra :: any()) -> {'ok', statename(), #state{}}).
code_change(_OldVsn, StateName, State, _Extra) ->
	{ok, StateName, State}.

% ======================================================================
% FORMAT_STATUS
% ======================================================================

%-spec(format_status/2 :: (Cause :: atom(), Data :: [any()]) -> any()).
%format_status(normal, [PDict, State]) ->
%	[{data, [{"State", format_status(terminate, [PDict, State])}]}];
%format_status(terminate, [_PDict, #state{agent_rec = Agent} = _State]) ->
%	% prevent client data from being dumped
%	Newagent = case Agent#agent.statedata of
%		#call{client = Client} = Call when is_record(Call#call.client, client) ->
%			Client = Call#call.client,
%			Agent#agent{statedata = Call#call{client = Client#client{options = []}}};
%		{onhold, #call{client = Client} = Call, calling, ID} when is_record(Client, client) ->
%			Agent#agent{statedata = {onhold, Call#call{client = Client#client{options = []}}, calling, ID}};
%		_ ->
%			Agent
%	end,
%	[Newagent#agent{password = "redacted"}].

% ======================================================================
% INTERNAL
% ======================================================================

priv_set_endpoint(_Agent, Module, {module, Module}) ->
	{error, self_reference};
priv_set_endpoint(Agent, Module, {module, OtherMod} = Endpoint) ->
	case dict:find(OtherMod, Agent#agent.endpoints) of
		error ->
			{error, module_noexists};
		{ok, _} ->
			NewEndpoints = dict:store(Module, Endpoint, Agent#agent.endpoints),
			NewAgent = Agent#agent{endpoints = NewEndpoints},
			inform_connection(Agent, {new_endpoint, Module, Endpoint}),
			{ok, NewAgent}
	end;
priv_set_endpoint(Agent, Module, Data) ->
	case Module:prepare_endpoint(Agent, Data) of
		{error, Err} ->
			{error, Err};
		{ok, NewData} ->
			NewEndpoints = dict:store(Module, NewData, Agent#agent.endpoints),
			NewAgent = Agent#agent{endpoints = NewEndpoints},
			inform_connection(Agent, {new_endpoint, Module, NewData}),
			{ok, NewAgent};
		Else ->
			{error, Else}
	end.

priv_set_endpoints(Agent, []) ->
	Agent;
priv_set_endpoints(Agent, [{Module, Data} | Tail]) ->
	case priv_set_endpoint(Agent, Module, Data) of
		{ok, NewAgent} ->
			priv_set_endpoints(NewAgent, Tail);
		_ ->
			priv_set_endpoints(Agent, Tail)
	end.

filter_endpoints(Endpoints) ->
	filter_endpoints(Endpoints, []).

filter_endpoints([], Acc) ->
	lists:reverse(Acc);
filter_endpoints([{Module, _Data} = Head | Tail], Acc) ->
	case proplists:get_value(Module, code:all_loaded()) of
		undefined ->
			filter_endpoints(Tail, Acc);
		_ ->
			case proplists:get_value(behaviour, Module:module_info(attributes)) of
				[gen_media] ->
					filter_endpoints(Tail, [Head | Acc]);
				_ ->
					filter_endpoints(Tail, Acc)
			end
	end.

inform_connection(#agent{connection = undefined}, _Msg) ->
	ok;
inform_connection(#agent{connection = Conn}, Msg) ->
	gen_server:cast(Conn, Msg).

start_channel(Agent, Call, StateName) ->
	ChanAvail = lists:member(Call#call.type, Agent#agent.available_channels),
	EndPoint = get_endpoint(Call#call.source_module, Agent),
	case {ChanAvail, EndPoint} of
		{false, _} -> 
			{error, nochannel};
		{true, {error, notfound}} ->
			{error, noendpoint};
		{true, Endpoint} ->
			Self = self(),
			case agent_channel:start_link(Agent, Call, Endpoint, StateName) of
				{ok, Pid} ->
					{Blocked, Available} = block_channels(Call#call.type, Agent#agent.available_channels, ?default_category_blocks),
					gen_server:cast(dispatch_manager, {now_avail, self(), Available}),
					gen_leader:cast(agent_manager, {set_avail, Agent#agent.login, Available}),
					NewAgent = Agent#agent{
						available_channels = Available,
						used_channels = dict:store(Pid, [Call#call.type | Blocked], Agent#agent.used_channels)
					},
					{ok, Pid, NewAgent};
				Else ->
					{error, Else}
			end
	end.

block_channels(Channel, CurrentAvail, BlocklistDefs) ->
	Blocklist = proplists:get_value(Channel, BlocklistDefs, []),
	TrueAvail = lists:delete(Channel, CurrentAvail),
	block_channels(Channel, TrueAvail, Blocklist, [], []).

block_channels(_Channel, CurrentAvail, none, _, _) ->
	{[], CurrentAvail};
block_channels(_Channel, CurrentAvail, all, _, _) ->
	{CurrentAvail, []};
block_channels(_Channel, [], _What, AccBlocked, AccAvail) ->
	{lists:reverse(AccBlocked), lists:reverse(AccAvail)};
block_channels(Channel, [Channel | Tail], self, AccBlocked, Avail) ->
	NewBlocked = [Channel | AccBlocked],
	block_channels(Channel, Tail, self, NewBlocked, Avail);
block_channels(Channel, [Channel | Tail], others, Blocked, AccAvail) ->
	NewAvail = [Channel | AccAvail],
	block_channels(Channel, Tail, others, Blocked, NewAvail);
block_channels(Channel, [Other | Tail], self, Blocked, AccAvail) ->
	NewAvail = [Other | AccAvail],
	block_channels(Channel, Tail, self, Blocked, NewAvail);
block_channels(Channel, [Other | Tail], others, AccBlocked, Avail) ->
	NewBlocked = [Other | AccBlocked],
	block_channels(Channel, Tail, others, NewBlocked, Avail);
block_channels(Channel, [Other | Tail], ToBlock, AccBlocked, AccAvail) ->
	{NewBlocked, NewAvail} = case lists:member(Other, ToBlock) of
		true -> {[Other | AccBlocked], AccAvail};
		false -> {AccBlocked, [Other | AccAvail]}
	end,
	block_channels(Channel, Tail, ToBlock, NewBlocked, NewAvail).

%% @private
-spec(agent_manager_exit/3 :: (Reason :: any(), StateName :: statename(), State :: #state{}) -> {'stop', 'normal', #state{}} | {'stop', 'shutdown', #state{}} | {'stop', 'timeout', #state{}} | {'next_state', statename(), #state{}}).
agent_manager_exit(Reason, StateName, State) ->
	case Reason of
		normal ->
			?INFO("Agent manager exited normally", []),
			{stop, normal, State};
		shutdown ->
			?INFO("Agent manager shutdown", []),
			{stop, shutdown, State};
		_Else ->
			?INFO("Agent manager exited abnormally with reason ~p", [Reason]),
			wait_for_agent_manager(5, StateName, State)
	end.

-spec(wait_for_agent_manager/3 :: (Count :: non_neg_integer(), StateName :: statename(), State :: #state{}) -> {'stop', 'timeout', #state{}} | {'next_state', statename(), #state{}}).
wait_for_agent_manager(0, _StateName, State) ->
	?WARNING("Timed out waiting for agent manager respawn", []),
	{stop, timeout, State};
wait_for_agent_manager(Count, StateName, #state{agent_rec = Agent} = State) ->
	case whereis(agent_manager) of
		undefined ->
			timer:sleep(1000),
			wait_for_agent_manager(Count - 1, StateName, State);
		Else when is_pid(Else) ->
			?INFO("Agent manager respawned as ~p", [Else]),
			% this will throw an error if the agent is already registered as
			% a different pid and that error will crash this process
			?INFO("Notifying new agent manager of agent ~p at ~p", [Agent#agent.login, self()]),
			Time = util:now(),
			agent_manager:notify(Agent#agent.login, Agent#agent.id, self(), Time, Agent#agent.skills),
			{next_state, StateName, State}
	end.

create_persistant_endpoint(Agent) ->
	case cpx:get_env(ring_manager) of
		undefined ->
			{error, no_ring_manager};
		{ok, Manager} ->
			gen_server:call(Manager, {ring, Agent, none})
	end.

set_cpx_monitor(State, Otherdeatils)->
	set_cpx_monitor(State, Otherdeatils, ignore).

set_cpx_monitor(State, Otherdeatils, Watch) ->
	log_change(State),
	Deatils = lists:append([
		{profile, State#agent.profile}, 
		{login, State#agent.login}, 
		{skills, State#agent.skills}], 
	Otherdeatils),
	cpx_monitor:set({agent, State#agent.id}, Deatils, Watch).

%log_change(#agent{log_pid = undefined}) ->
%	ok;
%log_change(#agent{log_pid = Pid, state = login} = State) when is_pid(Pid) ->
%	Pid ! {State#agent.login, State#agent.state, State#agent.oldstate, {State#agent.skills, State#agent.statedata}},
%	ok;
%log_change(#agent{log_pid = Pid} = State) when is_pid(Pid) ->
%	Pid ! State,
%	ok.

log_change(_) -> ok.

-spec(log_loop/4 :: (Id :: string(), Agentname :: string(), Nodes :: [atom()], Profile :: string() | {string(), string()}) -> 'ok').
log_loop(Id, Agentname, Nodes, ProfileTup) ->
	process_flag(trap_exit, true),
	Profile = case ProfileTup of
		{Currentp, _Queuedp} ->
			Currentp;
		_ ->
			ProfileTup
	end,
	receive
		{Agentname, login, State, {Skills, Statedata}} ->
			F = fun() ->
				Now = util:now(),
				Login = #agent_state{
					id = Id, 
					agent = Agentname, 
					oldstate = login, 
					state=State,
					statedata = Skills,
					start = Now, 
					ended = Now, 
					profile= Profile, 
					nodes = Nodes
				},
				StateRow = #agent_state{
					id = Id,
					agent = Agentname,
					oldstate = State,
					statedata = Statedata,
					start = Now,
					nodes = Nodes
				},
				mnesia:dirty_write(Login),
				mnesia:dirty_write(StateRow),
				gen_cdr_dumper:update_notify(agent_state),
				cpx_monitor:info({agent_state, Login}),
				cpx_monitor:info({agent_state, StateRow}),
				ok
			end,
			Res = mnesia:async_dirty(F),
			?DEBUG("res of agent state login:  ~p", [Res]),
			agent:log_loop(Id, Agentname, Nodes, ProfileTup);
		{'EXIT', _Apid, _Reason} ->
			F = fun() ->
				Now = util:now(),
				QH = qlc:q([Rec || Rec <- mnesia:table(agent_state), Rec#agent_state.id =:= Id, Rec#agent_state.ended =:= undefined]),
				Recs = qlc:e(QH),
				?DEBUG("Recs to loop through:  ~p", [Recs]),
				lists:foreach(
					fun(Untermed) ->
						mnesia:delete_object(Untermed), 
						Termed = Untermed#agent_state{ended = Now, timestamp = Now, state = logout},
						cpx_monitor:info({agent_state, Termed}),
						mnesia:write(Termed)
					end,
					Recs
				),
				gen_cdr_dumper:update_notify(agent_state),
				%Stateage = fun(#agent_state{start = A}, #agent_state{start = B}) ->
					%B =< A
				%end,
				%[#agent_state{state = Oldstate} | _] = lists:sort(Stateage, Recs),
				%Newrec = #agent_state{id = Id, agent = Agentname, state = logout, oldstate = State, statedata = "job done", start = Now, ended = Now, timestamp = Now, nodes = Nodes},
				%mnesia:write(Newrec),
				ok
			end,
			Res = mnesia:async_dirty(F),
			?DEBUG("res of agent state change log:  ~p", [Res]),
			ok;
		{change_profile, Newprofile, State} when State == idle; State == released ->
			agent:log_loop(Id, Agentname, Nodes, Newprofile);
		{change_profile, Newprofile, _State} ->
			case ProfileTup of
				{Current, _Queued} ->
					agent:log_loop(Id, Agentname, Nodes, {Current, Newprofile});
				Current ->
					agent:log_loop(Id, Agentname, Nodes, {Current, Newprofile})
			end;
		{Agentname, State, _OldState, Statedata} ->
			F = fun() ->
				Now = util:now(),
				QH = qlc:q([Rec || Rec <- mnesia:table(agent_state), Rec#agent_state.id =:= Id, Rec#agent_state.ended =:= undefined]),
				Recs = qlc:e(QH),
				lists:foreach(
					fun(Untermed) -> 
						mnesia:delete_object(Untermed),
						Termed = Untermed#agent_state{ended = Now, timestamp = Now, state = State},
						cpx_monitor:info({agent_state, Termed}),
						mnesia:write(Termed)
					end,
					Recs
				),
				gen_cdr_dumper:update_notify(agent_state),
				Newrec = #agent_state{id = Id, agent = Agentname, oldstate = State, statedata = Statedata, profile = Profile, start = Now, nodes = Nodes},
				cpx_monitor:info({agent_state, Newrec}),
				mnesia:write(Newrec),
				ok
			end,
			Res = mnesia:async_dirty(F),
			?DEBUG("res of agent ~p state change ~p log:  ~p", [Id, State, Res]),
			case {State, ProfileTup} of
				{State, {Profile, Queued}} when State == wrapup; State == idle; State == released ->
					agent:log_loop(Id, Agentname, Nodes, Queued);
				_ ->
					agent:log_loop(Id, Agentname, Nodes, ProfileTup)
			end
	end.
	
-ifdef(TEST).

%start_arbitrary_state_test() ->
%	{ok, Pid} = start(#agent{login = "testagent", state = idle}),
%	?assertEqual({ok, idle}, query_state(Pid)),
%	agent:stop(Pid).		

make_agent() ->
	make_agent([]).

make_agent(Opts) ->
	Fields = record_info(fields, agent),
	BaseAgent = #agent{
		login = "agent",
		source = self()
	},
	make_agent(Opts, Fields, BaseAgent).

make_agent([], _Fields, Agent) ->
	Agent;
make_agent([{Key, Value} | Tail], Fields, Agent) when is_atom(Key) ->
	NewAgent = case util:list_index(Key, Fields) of
		0 ->
			Agent;
		X ->
			setelement(X+1, Agent, Value)
	end,
	make_agent(Tail, Fields, NewAgent);
make_agent([_ | Tail], Fields, Agent) ->
	make_agent(Tail, Fields, Agent).
	
expand_magic_skills_test_() ->
	Agent = #agent{login = "testagent", profile = "testprofile", skills = ['_agent', '_node', '_profile', english, {'_brand', "testbrand"}]},
	Newskills = expand_magic_skills(Agent, Agent#agent.skills),
	[?_assert(lists:member({'_agent', "testagent"}, Newskills)),
	?_assert(lists:member({'_node', node()}, Newskills)),
	?_assert(lists:member(english, Newskills)),
	?_assert(lists:member({'_profile', "testprofile"}, Newskills)),
	?_assert(lists:member({'_brand', "testbrand"}, Newskills))].

block_channel_test_() ->
	FullAvail = [dummy, dummy, voice, voice, visual, visual, slow_text,
		slow_text, fast_text, fast_text],
	% {TestName, Channel, BlocListDefs, Expected}
	TestData = [{"blocks all", "nomatches", [{"nomatches", all}], {FullAvail, []}},
	{"blocks none", "nomatches", [{"nomatches", none}], {[], FullAvail}},
	{"blocks self", slow_text, ?default_category_blocks, {[slow_text], [dummy,
		 dummy, voice, voice, visual, visual, fast_text, fast_text]}},
	{"blocks others", fast_text, ?default_category_blocks, {[dummy, dummy,
		voice, voice, visual, visual, slow_text, slow_text], [fast_text]}},
	{"blocks specific", "channel", [{"channel", [visual, slow_text]}], {[
		visual, visual, slow_text, slow_text], [dummy, dummy, voice, voice,
		fast_text, fast_text]}}],
	block_channel_test_gen(TestData).

block_channel_test_gen([]) ->
	[];
block_channel_test_gen([{Name, Chan, ListDef, Expected} | Tail]) ->
	FullAvail = [dummy, dummy, voice, voice, visual, visual, slow_text,
		slow_text, fast_text, fast_text],
	{generator, fun() ->
		[{Name, fun() ->
			Out = block_channels(Chan, FullAvail, ListDef),
			?assertEqual(Expected, Out)
		end} | block_channel_test_gen(Tail)]
	end}.

handle_sync_event_test_() ->
	[{"handle set_endpoint", setup, fun() ->
			Endpoints = dict:from_list([
				{freeswitch_media, sip},
				{email_media, inband},
				{asterix, {module, freeswitch_media}}
			]),
			Agent = make_agent([{endpoints, Endpoints}]),
			State = #state{agent_rec = Agent},
			{Agent, State, Endpoints}
		end,
		fun({Agent, State, Endpoints}) -> [
			{"Adding new inband endpoint", fun() ->
				Expected = [{dummy_media, inband} | dict:to_list(Endpoints)],
				{reply, ok, idle, #state{agent_rec = NewAgent}} = handle_sync_event({set_endpoint, dummy_media, inband}, "from", idle, State),
				?assertEqual(lists:sort(Expected), lists:sort(dict:to_list(NewAgent#agent.endpoints)))
			end},

			{"Adding new module ref endpoint", fun() ->
				Expected = [{fast_text, {module, email_media}} | dict:to_list(Endpoints)],
				{reply, ok, idle, #state{agent_rec = NewAgent}} = handle_sync_event({set_endpoint, fast_text, {module, email_media}}, "from", idle, State),
				?assertEqual(lists:sort(Expected), lists:sort(dict:to_list(NewAgent#agent.endpoints)))
			end},

			{"Adding a self-refertial endpoint", fun() ->
				?assertEqual({reply, {error, self_reference}, idle, State}, handle_sync_event({set_endpoint, fast_text, {module, fast_text}}, "from", idle, State))
			end},

			{"adding a missing referencital endpoint", fun() ->
				?assertEqual({reply, {error, module_noexists}, idle, State}, handle_sync_event({set_endpoint, fast_text, {module, goober_pants}}, "from", idle, State))
				end},

			{"adding arbitary data endpoint", fun() ->
				Expected = [{dummy_media, inband} | dict:to_list(Endpoints)],
				{reply, ok, idle, #state{agent_rec = NewAgent}} = handle_sync_event({set_endpoint, dummy_media, inband}, "from", idle, State),
				?assertEqual(lists:sort(Expected), lists:sort(dict:to_list(NewAgent#agent.endpoints)))
			end}
		]
	end}].

-record(mock_pids, {
	state,
	dispatch_manager,
	cpx_monitor,
	agent_manager,
	connection,
	logger,
	assert
}).

from_release_test_() ->
	util:start_testnode(),
	Node = util:start_testnode(from_release_tests),
	{setup, {spawn, Node}, fun() -> ok end, fun(_) ->
	{foreach, fun() ->
		{ok, Dmock} = gen_server_mock:named({local, dispatch_manager}),
		{ok, Monmock} = cpx_monitor:make_mock(),
		{ok, AMmock} = gen_leader_mock:start(agent_manager),
		{ok, Connmock} = gen_server_mock:new(),
		{ok, Logpid} = gen_server_mock:new(),
		Agent = #agent{id = "testid", login = "testagent", connection = Connmock, log_pid = Logpid},
		Assertmocks = fun() ->
			gen_server_mock:assert_expectations(Dmock),
			%gen_leader_mock:assert_expectations(Monmock),
			cpx_monitor:assert_mock(),
			gen_server_mock:assert_expectations(Connmock),
			gen_server_mock:assert_expectations(Logpid),
			gen_leader_mock:assert_expectations(AMmock),
			ok
		end,
		MockPids = #mock_pids{
			state = #state{agent_rec = Agent},
			dispatch_manager = Dmock,
			cpx_monitor = Monmock,
			agent_manager = AMmock,
			connection = Connmock,
			logger = Logpid,
			assert = Assertmocks
		},
		%?ERROR("reference:  ~p", [MockPids]),
		MockPids
	end,
	fun(MockPids) ->
		gen_server_mock:stop(MockPids#mock_pids.dispatch_manager),
		%gen_leader_mock:stop(Monmock),
		cpx_monitor:stop_mock(),
		gen_server_mock:stop(MockPids#mock_pids.connection),
		gen_leader_mock:stop(MockPids#mock_pids.agent_manager),
		timer:sleep(10), % because the mock dispatch manager isn't dying quickly enough 
		% before the next test runs.
		ok
	end,
	[fun(#mock_pids{state = State, assert = AssertMocks} = Mocks) ->
		{"From release to release", fun() ->
			#state{agent_rec = Agent} = State,
			cpx_monitor:add_set({{agent, Agent#agent.id}, [{reason_id, "id"}, {reason, "label"}, {bias, -1}, {released, true}], ignore}),
			gen_server_mock:expect_cast(Mocks#mock_pids.connection, fun({set_release, {"id", "label", -1}, _Timestamp}, _State) -> ok end),
			gen_server_mock:expect_info(Mocks#mock_pids.logger, fun(#agent{release_data = {"id", "label", -1}}, _State) -> ok end),
			Out = released({set_release, {"id", "label", -1}}, "from", State),
			?assertMatch({reply, ok, released, _NewState}, Out),
			AssertMocks()
		end}
	end,
	fun(#mock_pids{state = State, assert = AssertMocks} = Mocks) ->
		{"From release to idle", fun() ->
			#state{agent_rec = Agent} = State,
			cpx_monitor:add_set({{agent, Agent#agent.id}, [{released, false}], ignore}),
			gen_leader_mock:expect_cast(Mocks#mock_pids.agent_manager, fun({set_avail, "testagent", InChans}, _State, _Elec) ->
				InChans = Agent#agent.available_channels,
				ok
			end),
			gen_server_mock:expect_cast(Mocks#mock_pids.connection, fun({set_release, none, _Time}, _State) -> ok end),
			gen_server_mock:expect_info(Mocks#mock_pids.logger, fun(#agent{id = "testid"}, _State) -> ok end),
			Self = self(),
			gen_server_mock:expect_cast(Mocks#mock_pids.dispatch_manager, fun({set_avail, InPid}, _State) ->
				InPid = Self,
				ok
			end),
			Out = released({set_release, none}, "from", State),
			?assertMatch({reply, ok, idle, _NewState}, Out),
			AssertMocks()
		end}
	end]} end}.
			
from_idle_test_() ->
	util:start_testnode(),
	Node = util:start_testnode(from_idle_tests),
	{setup, {spawn, Node}, fun() -> ok end, fun(_) ->
	{foreach, fun() ->
		{ok, Dmock} = gen_server_mock:named({local, dispatch_manager}),
		{ok, Monmock} = cpx_monitor:make_mock(),
		{ok, AMmock} = gen_leader_mock:start(agent_manager),
		{ok, Connmock} = gen_server_mock:new(),
		{ok, Logpid} = gen_server_mock:new(),
		Agent = #agent{id = "testid", login = "testagent", connection = Connmock, log_pid = Logpid},
		Assertmocks = fun() ->
			gen_server_mock:assert_expectations(Dmock),
			%gen_leader_mock:assert_expectations(Monmock),
			cpx_monitor:assert_mock(),
			gen_server_mock:assert_expectations(Connmock),
			gen_server_mock:assert_expectations(Logpid),
			gen_leader_mock:assert_expectations(AMmock),
			ok
		end,
		MockPids = #mock_pids{
			state = #state{agent_rec = Agent},
			dispatch_manager = Dmock,
			cpx_monitor = Monmock,
			agent_manager = AMmock,
			connection = Connmock,
			logger = Logpid,
			assert = Assertmocks
		},
		%?ERROR("reference:  ~p", [MockPids]),
		MockPids
	end,
	fun(MockPids) ->
		gen_server_mock:stop(MockPids#mock_pids.dispatch_manager),
		%gen_leader_mock:stop(Monmock),
		cpx_monitor:stop_mock(),
		gen_server_mock:stop(MockPids#mock_pids.connection),
		gen_leader_mock:stop(MockPids#mock_pids.agent_manager),
		timer:sleep(10), % because the mock dispatch manager isn't dying quickly enough 
		% before the next test runs.
		ok
	end,
	[fun(#mock_pids{state = State, assert = AssertMocks} = Mocks) ->
		{"From idle to idle", fun() ->
			Out = idle({set_release, none}, "from", State),
			?assertEqual({reply, ok, idle, State}, Out),
			AssertMocks()
		end}
	end,
	fun(#mock_pids{state = State, assert = AssertMocks} = Mocks) ->
		{"From idle to release", fun() ->
			#state{agent_rec = Agent} = State,
			cpx_monitor:add_set({{agent, Agent#agent.id}, [{released, true}, {reason, "label"}, {reason_id, "id"}, {bias, -1}], ignore}),
			gen_leader_mock:expect_cast(Mocks#mock_pids.agent_manager, fun({set_avail, "testagent", []}, _State, _Elec) -> ok end),
			gen_server_mock:expect_cast(Mocks#mock_pids.connection, fun({set_release, {"id", "label", -1}, _Time}, _State) -> ok end),
			gen_server_mock:expect_info(Mocks#mock_pids.logger, fun(#agent{id = "testid"}, _State) -> ok end),
			Self = self(),
			gen_server_mock:expect_cast(Mocks#mock_pids.dispatch_manager, fun({end_avail, InPid}, _State) ->
				InPid = Self,
				ok
			end),
			Out = idle({set_release, {"id", "label", -1}}, "from", State),
			?assertMatch({reply, ok, released, _NewState}, Out),
			AssertMocks()
		end}
	end]} end}.

-endif.
