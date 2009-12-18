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
%%	The Original Code is Spice Telephony.
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
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

%% @doc The connection handler that communicates with a client UI; in this case it's a dummy.

-module(agent_dummy_connection).

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).

-export([start/0, start/1, start_link/0, start_link/1, start_x/1, start_x/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
		code_change/3]).

-define(Major, 2).
-define(Minor, 0).

-include("log.hrl").
-include("call.hrl").
-include("agent.hrl").

-ifdef(R12B).
-type(boolean() :: bool()).
-endif.

-record(state, {
	ringing = random :: pos_integer() | {pos_integer(), pos_integer()} | 'random',
	ringtimer :: any(),
	oncall = random :: pos_integer() | {pos_integer(), pos_integer()} | 'random',
	calltimer :: any(),
	wrapup = random :: pos_integer() | {pos_integer(), pos_integer()} | 'random',
	wrapuptimer :: any(),
	scale = 1 :: pos_integer(),
	maxcalls = unlimited :: pos_integer() | 'unlimited',
	call :: #call{} | 'undefined',
	agent_fsm :: pid(),
	life_watch :: any(),
	release_data = {false, 0, undefined} :: {boolean(), {non_neg_integer(), non_neg_integer()}, any()} % TODO - this spec is wrong, but I don't know why
}).

-type(state() :: #state{}).
-define(GEN_SERVER, true).
-include("gen_spec.hrl").

-spec(start_x/1 :: (N :: pos_integer()) -> 'ok').
start_x(N) ->
	start_x(N, []).

-spec(start_x/2 :: (N :: pos_integer(), Args :: [any()]) -> 'ok').
start_x(N, Args) ->
	F = fun(_I) ->
		start(Args)
	end,
	lists:foreach(F, lists:seq(1, N)).

-spec(start/0 :: () -> {'ok', pid()}).
start() ->
	start([]).
	
-spec(start/1 :: (Args :: [any()]) -> {'ok', pid()}).
start(Args) ->
	gen_server:start(?MODULE, [Args], []).

-spec(start_link/0 :: () -> {'ok', pid()}).
start_link() ->
	start_link([]).

-spec(start_link/1 :: (Args :: [any()]) -> {'ok', pid()}).
start_link(Args) ->
	gen_server:start_link(?MODULE, [Args], []).

init([Args]) ->
	crypto:start(),
	Login = proplists:get_value(login, Args, lists:flatten(io_lib:format("~p", [make_ref()]))),
	{ok, Pid} = agent_manager:start_agent(#agent{
			id = proplists:get_value(id, Args, Login),
			login = Login,
			profile = proplists:get_value(profile, Args, "Default"),
			skills = proplists:get_value(skills, Args, [english, '_agent', '_node'])
		}),
	ok = agent:set_state(Pid, idle),
	agent:set_connection(Pid, self()),
	?NOTICE("Created new dummy agent connection", []),
	Lifewatch = case proplists:get_value(max_life, Args) of
		undefined ->
			undefined;
		Number ->
			{ok, Timer} = timer:send_after(Number * 1000, <<"hagurk">>),
			Timer
	end,
	Release_data = case proplists:get_value(release_frequency, Args) of
		undefined ->
			{false, 0, undefined};
		Alsonumber ->
			Actualreleased = get_time(Alsonumber),
			{ok, RelTimer} = timer:send_after(Actualreleased * 1000, <<"toggle_release">>),
			{false, {Alsonumber, (proplists:get_value(release_percent, Args, 10) / 100)}, RelTimer}
	end,
	{ok, #state{
		agent_fsm = Pid,
		ringing = proplists:get_value(ringing, Args, random),
		oncall = proplists:get_value(oncall, Args, random),
		wrapup = proplists:get_value(wrapup, Args, random),
		maxcalls = proplists:get_value(maxcalls, Args, unlimited),
		scale = proplists:get_value(scale, Args, 1),
		life_watch = Lifewatch,
		release_data = Release_data}}.

handle_call(Request, _From, State) ->
	{reply, {unknown_call, Request}, State}.

handle_cast({change_state, ringing, #call{} = Call}, State) ->
	Time = get_time(State#state.ringing) * State#state.scale,
	?INFO("answering call after ~p", [Time]),
	Tref = timer:send_after(Time, answer),
	{noreply, State#state{ringtimer = Tref, call = Call}};
handle_cast({change_state, oncall, #call{} = Call}, State) ->
	timer:cancel(State#state.ringtimer),
	Time = get_time(State#state.oncall) * State#state.scale,
	?INFO("hanging up call after ~p", [Time]),
	Tref = timer:send_after(Time, hangup),
	{noreply, State#state{ringtimer = undefined, calltimer = Tref, call = Call}};
handle_cast({change_state, wrapup, #call{} = Call}, State) ->
	timer:cancel(State#state.calltimer),
	Time = get_time(State#state.wrapup) * State#state.scale,
	?INFO("ending wrapup after ~p", [Time]),
	Tref = timer:send_after(Time, endwrapup),
	{noreply, State#state{calltimer = undefined, wrapuptimer = Tref, call = Call}};
handle_cast({change_state, _AgState, _Data}, State) ->
	{noreply, State};
handle_cast({change_state, idle}, State) ->
	?INFO("going idle", []),
	timer:cancel(State#state.ringtimer),
	timer:cancel(State#state.calltimer),
	timer:cancel(State#state.wrapuptimer),
	{noreply, State#state{ringtimer = undefined, calltimer = undefined, wrapuptimer = undefined, call = undefined}};
handle_cast({change_state, _AgState}, State) ->
	{noreply, State};
handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info(<<"toggle_release">>, #state{release_data = {false, {Frequency, Percent} = Nums, _Timer}} = State) ->
	case agent:set_state(State#state.agent_fsm, released, "Default") of
		ok ->
			ok;
		queued ->
			queued
	end,
	Newtime = round(get_time(Frequency) * Percent) * 1000,
	{ok, Newtimer} = timer:send_after(Newtime, <<"toggle_release">>),
	{noreply, State#state{release_data = {true, Nums, Newtimer}}};
handle_info(<<"toggle_release">>, #state{release_data = {true, {Frequency, _Percent} = Nums, _Timer}, calltimer = Calltimer} = State) ->
	case Calltimer of
		undefined ->
			ok = agent:set_state(State#state.agent_fsm, idle);
		_Else ->
			ok = agent:set_state(State#state.agent_fsm, released, undefined)
	end,
	{ok, Newtimer} = timer:send_after(round(get_time(Frequency) * 1000), <<"toggle_release">>),
	{noreply, State#state{release_data = {false, Nums, Newtimer}}};
handle_info(<<"hagurk">>, State) ->
	{stop, normal, State};
handle_info(answer, #state{call = Call} = State) when is_record(Call, call)->
	?INFO("time to answer", []),
	%gen_server:call(Call#call.source, unqueue),
	case Call#call.ring_path of
		inband ->
			ok = agent:set_state(State#state.agent_fsm, oncall);
		outband ->
			ok = agent:set_state(State#state.agent_fsm, oncall, State#state.call)
	end,
	gen_server:cast(Call#call.cook, remove_from_queue),
	{noreply, State};
handle_info(hangup, #state{call = Call} = State) when is_record(Call, call) ->
	?INFO("time to hangup", []),
	case Call#call.ring_path of
		inband ->
			ok = agent:set_state(State#state.agent_fsm, wrapup);
		outband ->
			ok = agent:set_state(State#state.agent_fsm, wrapup, State#state.call)
	end,
	{noreply, State};
handle_info(endwrapup, #state{call = Call} = State) when is_record(Call, call) ->
	?INFO("time to endwrapup", []),
	ok = agent:set_state(State#state.agent_fsm, idle),
	case State#state.maxcalls of
		unlimited -> {noreply, State};
		SomeNumber when (SomeNumber - 1) =< 0 ->
			{stop, shutdown, State};
		SomeNumber ->
			{noreply, State#state{call = undefined, maxcalls = SomeNumber - 1}}
	end;
handle_info(_Info, State) ->
	{noreply, State}.

get_time({distribution, Number}) ->
	trunc(util:distribution(Number));
get_time(random) ->
	crypto:rand_uniform(0, 300);
get_time({Min, Max}) ->
	crypto:rand_uniform(Min, Max);
get_time(T) ->
	T.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

