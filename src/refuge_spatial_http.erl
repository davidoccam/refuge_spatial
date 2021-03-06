%%% -*- erlang -*-
%%%
%%% This file is part of refuge_spatial released under the Apache license 2.
%%% See the NOTICE for more information.

-module(refuge_spatial_http).

-export([handle_spatial_req/3, handle_info_req/3, handle_compact_req/3,
    handle_cleanup_req/2, parse_qs/1]).

-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_httpd/include/couch_httpd.hrl").
-include_lib("refuge_spatial/include/refuge_spatial.hrl").

-record(acc, {
    db,
    req,
    resp,
    prepend,
    etag
}).

% Either answer a normal spatial query, or keep dispatching if the path part
% after _spatial starts with an underscore.
handle_spatial_req(#httpd{
        path_parts=[_, _, _Dname, _, SpatialName|_]}=Req, Db, DDoc) ->
    case SpatialName of
    % the path after _spatial starts with an underscore => dispatch
    <<$_,_/binary>> ->
        dispatch_sub_spatial_req(Req, Db, DDoc);
    _ ->
        handle_spatial(Req, Db, DDoc)
    end.

% the dispatching of endpoints below _spatial needs to be done manually
dispatch_sub_spatial_req(#httpd{
        path_parts=[_, _, _DName, Spatial, SpatialDisp|_]}=Req,
        Db, DDoc) ->
    Conf = couch_config:get("httpd_design_handlers",
        ?b2l(<<Spatial/binary, "/", SpatialDisp/binary>>)),
    Fun = couch_httpd:make_arity_3_fun(Conf),
    apply(Fun, [Req, Db, DDoc]).


handle_spatial(#httpd{method='GET'}=Req, Db, DDoc) ->
    [_, _, DName, _, ViewName] = Req#httpd.path_parts,
    ?LOG_DEBUG("Spatial query (~p): ~n~p", [DName, DDoc#doc.id]),
    couch_stats_collector:increment({httpd, spatial_view_reads}),
    design_doc_view(Req, Db, DDoc, ViewName);
handle_spatial(Req, _Db, _DDoc) ->
    couch_httpd:send_method_not_allowed(Req, "GET,HEAD").


handle_info_req(#httpd{method='GET'}=Req, Db, DDoc) ->
    [_, _, DesignName, _, _] = Req#httpd.path_parts,
    {ok, GroupInfoList} = refuge_spatial:get_info(Db, DDoc),
    couch_httpd:send_json(Req, 200, {[
        {name, DesignName},
        {spatial_index, {GroupInfoList}}
    ]});
handle_info_req(Req, _Db, _DDoc) ->
    couch_httpd:send_method_not_allowed(Req, "GET").


handle_compact_req(#httpd{method='POST'}=Req, Db, DDoc) ->
    ok = couch_db:check_is_admin(Db),
    couch_httpd:validate_ctype(Req, "application/json"),
    ok = refuge_spatial:compact(Db, DDoc),
    couch_httpd:send_json(Req, 202, {[{ok, true}]});
handle_compact_req(Req, _Db, _DDoc) ->
    couch_httpd:send_method_not_allowed(Req, "POST").


handle_cleanup_req(#httpd{method='POST'}=Req, Db) ->
    % delete unreferenced index files
    ok = couch_db:check_is_admin(Db),
    couch_httpd:validate_ctype(Req, "application/json"),
    ok = refuge_spatial:cleanup(Db),
    couch_httpd:send_json(Req, 202, {[{ok, true}]});
handle_cleanup_req(Req, _Db) ->
    couch_httpd:send_method_not_allowed(Req, "POST").



design_doc_view(Req, Db, DDoc, ViewName) ->
    Args = parse_qs(Req),
    design_doc_view(Req, Db, DDoc, ViewName, Args).

design_doc_view(Req, Db, DDoc, ViewName, #spatial_args{count=true}=Args) ->
    Count = refuge_spatial:query_view_count(Db, DDoc, ViewName, Args),
    couch_httpd:send_json(Req, {[{count, Count}]});
design_doc_view(Req, Db, DDoc, ViewName, Args0) ->
    EtagFun = fun(Sig, Acc0) ->
        Etag = couch_httpd:make_etag(Sig),
        case couch_httpd:etag_match(Req, Etag) of
            true -> throw({etag_match, Etag});
            false -> {ok, Acc0#acc{etag=Etag}}
        end
    end,
    Args = Args0#spatial_args{preflight_fun=EtagFun},
    {ok, Resp} = couch_httpd:etag_maybe(Req, fun() ->
        VAcc = #acc{db=Db, req=Req},
        refuge_spatial:query_view(
            Db, DDoc, ViewName, Args, fun spatial_cb/2, VAcc)
    end),
    case is_record(Resp, acc) of
        true -> {ok, Resp#acc.resp};
        _ -> {ok, Resp}
    end.


spatial_cb({meta, Meta}, #acc{resp=undefined}=Acc) ->
    Headers = [{"ETag", Acc#acc.etag}],
    {ok, Resp} = couch_httpd:start_json_response(Acc#acc.req, 200, Headers),
    % Map function starting
    Parts = case couch_util:get_value(offset, Meta) of
        undefined -> [];
        Offset -> [io_lib:format("\"offset\":~p", [Offset])]
    end ++ case couch_util:get_value(update_seq, Meta) of
        undefined -> [];
        UpdateSeq -> [io_lib:format("\"update_seq\":~p", [UpdateSeq])]
    end ++ ["\"rows\":["],
    Chunk = lists:flatten("{" ++ string:join(Parts, ",") ++ "\r\n"),
    couch_httpd:send_chunk(Resp, Chunk),
    {ok, Acc#acc{resp=Resp, prepend=""}};
spatial_cb({row, Row}, Acc) ->
    % Adding another row
    couch_httpd:send_chunk(
        Acc#acc.resp, [Acc#acc.prepend, row_to_json(Row)]),
    {ok, Acc#acc{prepend=",\r\n"}};
spatial_cb(complete, #acc{resp=undefined}=Acc) ->
    % Nothing in view
    {ok, Resp} = couch_httpd:send_json(Acc#acc.req, 200, {[{rows, []}]}),
    {ok, Acc#acc{resp=Resp}};
spatial_cb(complete, Acc) ->
    % Finish view output
    couch_httpd:send_chunk(Acc#acc.resp, "\r\n]}"),
    couch_httpd:end_json_response(Acc#acc.resp),
    {ok, Acc}.

row_to_json({{Bbox, DocId}, {Geom, Value}}) ->
    Obj = {[
        {<<"id">>, DocId},
        {<<"bbox">>, erlang:tuple_to_list(Bbox)},
        {<<"geometry">>, refuge_spatial_updater:geocouch_to_geojsongeom(Geom)},
        {<<"value">>, Value}]},
    ?JSON_ENCODE(Obj).


parse_qs(Req) ->
    lists:foldl(fun({K, V}, Acc) ->
        parse_qs(K, V, Acc)
    end, #spatial_args{}, couch_httpd:qs(Req)).


parse_qs(Key, Val, Args) ->
    case Key of
    "" ->
        Args;
    "bbox" ->
        Args#spatial_args{
            bbox=list_to_tuple(?JSON_DECODE("[" ++ Val ++ "]"))};
    "stale" when Val == "ok" ->
        Args#spatial_args{stale=ok};
    "stale" when Val == "update_after" ->
        Args#spatial_args{stale=update_after};
    "stale" ->
        throw({query_parse_error,
            <<"stale only available as stale=ok or as stale=update_after">>});
    "count" when Val == "true" ->
        Args#spatial_args{count=true};
    "count" ->
        throw({query_parse_error, <<"count only available as count=true">>});
    "plane_bounds" ->
        Args#spatial_args{
            bounds=list_to_tuple(?JSON_DECODE("[" ++ Val ++ "]"))};
    "limit" ->
        Args#spatial_args{limit=parse_int(Val)};
    "skip" ->
        Args#spatial_args{skip=parse_int(Val)};
    _ ->
        BKey = list_to_binary(Key),
        BVal = list_to_binary(Val),
        Args#spatial_args{extra=[{BKey, BVal} | Args#spatial_args.extra]}
    end.


% Verbatim copy from couch_mrview_http
parse_int(Val) ->
    case (catch list_to_integer(Val)) of
    IntVal when is_integer(IntVal) ->
        IntVal;
    _ ->
        Msg = io_lib:format("Invalid value for integer parameter: ~p", [Val]),
        throw({query_parse_error, ?l2b(Msg)})
    end.
