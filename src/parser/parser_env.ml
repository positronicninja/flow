(*
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Ast
module Error = Parse_error
module SSet = Set.Make(String)

module Lex_mode = struct
  type t =
    | NORMAL
    | TYPE
    | JSX_TAG
    | JSX_CHILD
    | TEMPLATE
    | REGEXP

  let debug_string_of_lex_mode (mode: t) =
    match mode with
    | NORMAL -> "NORMAL"
    | TYPE -> "TYPE"
    | JSX_TAG -> "JSX_TAG"
    | JSX_CHILD -> "JSX_CHILD"
    | TEMPLATE -> "TEMPLATE"
    | REGEXP -> "REGEXP"
end

(* READ THIS BEFORE YOU MODIFY:
 *
 * The current implementation for lookahead beyond a single token is
 * inefficient. If you believe you need to increase this constant, do one of the
 * following:
 * - Find another way
 * - Benchmark your change and provide convincing evidence that it doesn't
 *   actually have a significant perf impact.
 * - Refactor this to memoize all requested lookahead, so we aren't lexing the
 *   same token multiple times.
 *)
let maximum_lookahead = 2

module Lookahead : sig
  type t
  val create : Lex_env.t -> Lex_mode.t -> t
  val peek : t -> int -> Lex_result.t
  val lex_env : t -> int -> Lex_env.t
  val junk : t -> unit
end = struct
  type t = {
    mutable la_results    : (Lex_env.t * Lex_result.t) option array;
    mutable la_num_lexed  : int;
    la_lex_mode           : Lex_mode.t;
    mutable la_lex_env    : Lex_env.t;
  }

  let create lex_env mode =
    let lexbuf = Lex_env.lexbuf lex_env in
    (* copy all the mutable things so that we have a distinct lexing environment
     * that does not interfere with ordinary lexer operations *)
    (* lex_buffer has type bytes, which is itself mutable, but the lexer
     * promises not to change it so a shallow copy should be fine *)
    (* I don't know how to do a copy without an update *)
    let lexbuf = lexbuf |> Obj.repr |> Obj.dup |> Obj.obj in
    let lex_env = Lex_env.with_lexbuf ~lexbuf lex_env in
    {
      la_results = [||];
      la_num_lexed = 0;
      la_lex_mode = mode;
      la_lex_env = lex_env;
    }

  let next_power_of_two n =
    let rec f i =
      if i >= n then
        i
      else
        f (i * 2) in
    f 1

  (* resize the tokens array to have at least n elements *)
  let grow t n =
    if Array.length t.la_results < n then begin
      let new_size = next_power_of_two n in
      let filler i =
        if i < Array.length t.la_results then
          t.la_results.(i)
        else
          None in
      let new_arr = Array.init new_size filler in
      t.la_results <- new_arr
    end

  (* precondition: there is enough room in t.la_results for the result *)
  let lex t =
    let lex_env = t.la_lex_env in
    let lex_env, lex_result =
      match t.la_lex_mode with
      | Lex_mode.NORMAL -> Lexer.token lex_env
      | Lex_mode.TYPE -> Lexer.type_token lex_env
      | Lex_mode.JSX_TAG -> Lexer.jsx_tag lex_env
      | Lex_mode.JSX_CHILD -> Lexer.jsx_child lex_env
      | Lex_mode.TEMPLATE -> Lexer.template_tail lex_env
      | Lex_mode.REGEXP -> Lexer.regexp lex_env
    in
    let cloned_env =
      let lexbuf =
        Lex_env.lexbuf lex_env
        |> Obj.repr
        |> Obj.dup
        |> Obj.obj
      in
      Lex_env.with_lexbuf ~lexbuf lex_env
    in
    t.la_lex_env <- lex_env;
    t.la_results.(t.la_num_lexed) <- Some (cloned_env, lex_result);
    t.la_num_lexed <- t.la_num_lexed + 1

  let lex_until t i =
    grow t (i + 1);
    while t.la_num_lexed <= i do
      lex t
    done

  let peek t i =
    lex_until t i;
    match t.la_results.(i) with
      | Some (_, result) -> result
      (* only happens if there is a defect in the lookahead module *)
      | None -> failwith "Lookahead.peek failed"

  let lex_env t i =
    lex_until t i;
    match t.la_results.(i) with
      | Some (lex_env, _) -> lex_env
      (* only happens if there is a defect in the lookahead module *)
      | None -> failwith "Lookahead.peek failed"

  (* Throws away the first peeked-at token, shifting any subsequent tokens up *)
  let junk t =
    lex_until t 0;
    if t.la_num_lexed > 1 then
      Array.blit t.la_results 1 t.la_results 0 (t.la_num_lexed - 1);
    t.la_results.(t.la_num_lexed - 1) <- None;
    t.la_num_lexed <- t.la_num_lexed - 1;
end

type token_sink_result = {
  token_loc: Loc.t;
  token: Token.t;
  token_context: Lex_mode.t;
}

type parse_options = {
  esproposal_class_instance_fields: bool;
  esproposal_class_static_fields: bool;
  esproposal_decorators: bool;
  esproposal_export_star_as: bool;
  types: bool;
  use_strict: bool;
}
let default_parse_options = {
  esproposal_class_instance_fields = false;
  esproposal_class_static_fields = false;
  esproposal_decorators = false;
  esproposal_export_star_as = false;
  types = true;
  use_strict = false;
}

type allowed_super =
  | No_super
  | Super_prop
  | Super_prop_or_call

type env = {
  errors                : (Loc.t * Error.t) list ref;
  comments              : Comment.t list ref;
  labels                : SSet.t;
  exports               : SSet.t ref;
  last_lex_result       : Lex_result.t option ref;
  in_strict_mode        : bool;
  in_export             : bool;
  in_loop               : bool;
  in_switch             : bool;
  in_formal_parameters  : bool;
  in_function           : bool;
  no_in                 : bool;
  no_call               : bool;
  no_let                : bool;
  no_anon_function_type : bool;
  no_new                : bool;
  allow_yield           : bool;
  allow_await           : bool;
  allow_directive       : bool;
  allow_super           : allowed_super;
  error_callback        : (env -> Error.t -> unit) option;
  lex_mode_stack        : Lex_mode.t list ref;
  (* lex_env is the lex_env after the single lookahead has been lexed *)
  lex_env               : Lex_env.t ref;
  (* This needs to be cleared whenever we advance. *)
  lookahead             : Lookahead.t ref;
  token_sink            : (token_sink_result -> unit) option ref;
  parse_options         : parse_options;
  source                : Loc.filename option;
  (* It is a syntax error to reference private fields not in scope. In order to enforce this,
   * we keep track of the privates we've seen declared and used. *)
  privates              : (SSet.t * ((string * Loc.t) list)) list ref;
}

(* constructor *)
let init_env ?(token_sink=None) ?(parse_options=None) source content =
  (* let lb = Sedlexing.Utf16.from_string
    content (Some Sedlexing.Utf16.Little_endian) in *)
  let lb, errors = try Sedlexing.Utf8.from_string content, []
  with Sedlexing.MalFormed ->
    Sedlexing.Utf8.from_string "",
    [ { Loc.none with Loc.source; }, Parse_error.MalformedUnicode ]
  in

  let parse_options =
    match parse_options with
    | Some opts -> opts
    | None -> default_parse_options
  in
  let enable_types_in_comments = parse_options.types in
  let lex_env = Lex_env.new_lex_env source lb ~enable_types_in_comments in
  {
    errors = ref errors;
    comments = ref [];
    labels = SSet.empty;
    exports = ref SSet.empty;
    last_lex_result = ref None;
    in_strict_mode = parse_options.use_strict;
    in_export = false;
    in_loop = false;
    in_switch = false;
    in_formal_parameters = false;
    in_function = false;
    no_in = false;
    no_call = false;
    no_let = false;
    no_anon_function_type = false;
    no_new = false;
    allow_yield = false;
    allow_await = false;
    allow_directive = false;
    allow_super = No_super;
    error_callback = None;
    lex_mode_stack = ref [Lex_mode.NORMAL];
    lex_env = ref lex_env;
    lookahead = ref (Lookahead.create lex_env Lex_mode.NORMAL);
    token_sink = ref token_sink;
    parse_options;
    source;
    privates = ref [];
  }

(* getters: *)
let in_strict_mode env = env.in_strict_mode
let lex_mode env = List.hd !(env.lex_mode_stack)
let in_export env = env.in_export
let comments env = !(env.comments)
let labels env = env.labels
let in_loop env = env.in_loop
let in_switch env = env.in_switch
let in_formal_parameters env = env.in_formal_parameters
let in_function env = env.in_function
let allow_yield env = env.allow_yield
let allow_await env = env.allow_await
let allow_directive env = env.allow_directive
let allow_super env = env.allow_super
let no_in env = env.no_in
let no_call env = env.no_call
let no_let env = env.no_let
let no_anon_function_type env = env.no_anon_function_type
let no_new env = env.no_new
let errors env = !(env.errors)
let parse_options env = env.parse_options
let source env = env.source
let should_parse_types env = env.parse_options.types

(* mutators: *)
let error_at env (loc, e) =
  env.errors := (loc, e) :: !(env.errors);
  match env.error_callback with
  | None -> ()
  | Some callback -> callback env e
let comment_list env =
  List.iter (fun c -> env.comments := c :: !(env.comments))
let record_export env (loc, export_name) =
  if export_name = "" then () else (* empty identifiers signify an error, don't export it *)
  let exports = !(env.exports) in
  if SSet.mem export_name exports
  then error_at env (loc, Error.DuplicateExport export_name)
  else env.exports := SSet.add export_name !(env.exports)

(* Since private fields out of scope are a parse error, we keep track of the declared and used
 * private fields.
 *
 * Whenever we enter a class, we push new empty lists of declared and used privates.
 * When we encounter a new declared private, we add it to the top of the declared_privates list
 * via add_declared_private. We do the same with used_privates via add_used_private.
 *
 * When we exit a class, we look for all the unbound private variables. Since class fields
 * are hoisted to the scope of the class, we may need to look further before we conclude that
 * a field is out of scope. To do that, we add all of the unbound private fields to the
 * next used_private list. Once we run out of declared private lists, any leftover used_privates
 * are unbound private variables. *)
let enter_class env = env.privates := (SSet.empty, []) :: !(env.privates)

let exit_class env =

  let get_unbound_privates declared_privates used_privates =
    List.filter (fun x -> not (SSet.mem (fst x) declared_privates)) used_privates in

  match !(env.privates) with
  | [declared_privates, used_privates] ->
      let unbound_privates = get_unbound_privates declared_privates used_privates in
      List.iter (fun (name, loc) -> error_at env (loc, Error.UnboundPrivate name)) unbound_privates;
      env.privates := []
  | (loc_declared_privates, loc_used_privates) :: privates ->
      let unbound_privates = get_unbound_privates loc_declared_privates loc_used_privates in
      let decl_head, used_head = List.hd privates in
      env.privates := (decl_head, used_head @ unbound_privates) :: (List.tl privates)
  | _ -> failwith "Internal Error: `exit_class` called before a matching `enter_class`"

let add_declared_private env name =
  match !(env.privates) with
  | [] -> failwith "Internal Error: Tried to add_declared_private with outside of class scope."
  | (declared, used)::xs -> env.privates := ((SSet.add name declared, used) :: xs)

let add_used_private env name loc =
  match !(env.privates) with
  | [] -> error_at env (loc, Error.PrivateNotInClass)
  | (declared, used)::xs -> env.privates := ((declared, (name, loc) :: used) :: xs)

(* lookahead: *)
let lookahead ?(i=0) env =
  assert (i < maximum_lookahead);
  Lookahead.peek !(env.lookahead) i

(* functional operations: *)
let with_strict in_strict_mode env = { env with in_strict_mode }
let with_in_formal_parameters in_formal_parameters env = { env with in_formal_parameters }
let with_in_function in_function env = { env with in_function }
let with_allow_yield allow_yield env = { env with allow_yield }
let with_allow_await allow_await env = { env with allow_await }
let with_allow_directive allow_directive env = { env with allow_directive }
let with_allow_super allow_super env = { env with allow_super }
let with_no_let no_let env = { env with no_let }
let with_in_loop in_loop env = { env with in_loop }
let with_no_in no_in env = { env with no_in }
let with_no_anon_function_type no_anon_function_type env =
  { env with no_anon_function_type }
let with_no_new no_new env = { env with no_new }
let with_in_switch in_switch env = { env with in_switch }
let with_in_export in_export env = { env with in_export }
let with_no_call no_call env = { env with no_call }
let with_error_callback error_callback env =
  { env with error_callback = Some error_callback }

(* other helper functions: *)
let error_list env = List.iter (error_at env)
let last_loc env = match !(env.last_lex_result) with
| Some lex_result -> Some (Lex_result.loc lex_result)
| None -> None

let last_token env = match !(env.last_lex_result) with
| Some lex_result -> Some (Lex_result.token lex_result)
| None -> None

let without_error_callback env = { env with error_callback = None }

let add_label env label = { env with labels = SSet.add label env.labels }
let enter_function env ~async ~generator = { env with
    in_formal_parameters = false;
    in_function = true;
    in_loop = false;
    in_switch = false;
    labels = SSet.empty;
    allow_await = async;
    allow_yield = generator;
  }

(* #sec-keywords *)
let is_keyword = function
  | "await" | "break" | "case" | "catch" | "class" | "const" | "continue"
  | "debugger" | "default" | "delete" | "do" | "else" | "export" | "extends"
  | "finally" | "for" | "function" | "if" | "import" | "in" | "instanceof"
  | "new" | "return" | "super" | "switch" | "this" | "throw" | "try"
  | "typeof" | "var" | "void" | "while" | "with" | "yield" -> true
  | _ -> false

(* #sec-future-reserved-words *)
let is_future_reserved = function
  | "enum" -> true
  | _ -> false

let token_is_future_reserved = Token.(function
  | T_IDENTIFIER { raw; _ } when is_future_reserved raw -> true
  | T_ENUM -> true
  | _ -> false
)

(* #sec-strict-mode-of-ecmascript *)
let is_strict_reserved = function
  | "interface"
  | "implements"
  | "package"
  | "private"
  | "protected"
  | "public"
  | "static"
  | "yield" -> true
  | _ -> false

let token_is_strict_reserved = Token.(function
  | T_IDENTIFIER { raw; _ } when is_strict_reserved raw -> true
  | T_INTERFACE
  | T_IMPLEMENTS
  | T_PACKAGE
  | T_PRIVATE
  | T_PROTECTED
  | T_PUBLIC
  | T_STATIC
  | T_YIELD
    -> true
  | _
    -> false
)

(* #sec-strict-mode-of-ecmascript *)
let is_restricted = function
  | "eval"
  | "arguments" -> true
  | _ -> false

let token_is_restricted = Token.(function
  | T_IDENTIFIER { raw; _ } when is_restricted raw -> true
  | _ -> false
)

(* #sec-reserved-words *)
let is_reserved str_val =
  is_keyword str_val ||
  is_future_reserved str_val ||
  match str_val with
  | "null" | "true" | "false" -> true
  | _ -> false

let is_reserved_type str_val =
  match str_val with
  | "any" | "bool" | "boolean" | "empty" | "false" | "mixed" | "null"
  | "number" | "static" | "string" | "true" | "typeof" | "void" -> true
  | _ -> false

(* Answer questions about what comes next *)
module Peek = struct
  open Loc
  open Token

  let token ?(i=0) env = Lex_result.token (lookahead ~i env)
  let loc ?(i=0) env = Lex_result.loc (lookahead ~i env)
  let errors ?(i=0) env = Lex_result.errors (lookahead ~i env)
  let comments ?(i=0) env = Lex_result.comments (lookahead ~i env)
  let lex_env ?(i=0) env = Lookahead.lex_env !(env.lookahead) i

  (* True if there is a line terminator before the next token *)
  let is_line_terminator env =
    match last_loc env with
      | None -> false
      | Some loc' ->
          (loc env).start.line > loc'.start.line

  let is_implicit_semicolon env =
    match token env with
    | T_EOF | T_RCURLY -> true
    | T_SEMICOLON -> false
    | _ -> is_line_terminator env

  (* This returns true if the next token is identifier-ish (even if it is an
   * error) *)
  let is_identifier ?(i=0) env =
    match token ~i env with
    | t when token_is_strict_reserved t -> true
    | t when token_is_future_reserved t -> true
    | t when token_is_restricted t -> true
    | T_LET
    | T_TYPE
    | T_OPAQUE
    | T_OF
    | T_DECLARE
    | T_ASYNC
    | T_AWAIT
    | T_POUND
    | T_IDENTIFIER _ -> true
    | _ -> false

  let is_literal_property_name ?(i=0) env =
    is_identifier ~i env || match token ~i env with
    | T_STRING _
    | T_NUMBER _ -> true
    | _ -> false

  let is_function ?(i=0) env =
    token ~i env = T_FUNCTION ||
    (token ~i env = T_ASYNC && token ~i:(i+1) env = T_FUNCTION)

  let is_class ?(i=0) env =
    match token ~i env with
    | T_CLASS
    | T_AT -> true
    | _ -> false
end


(*****************************************************************************)
(* Errors *)
(*****************************************************************************)

(* Complains about an error at the location of the lookahead *)
let error env e =
  let loc = Peek.loc env in
  error_at env (loc, e)

let get_unexpected_error token =
  let open Token in
  match token with
  | T_EOF -> Error.UnexpectedEOS
  | T_NUMBER _ -> Error.UnexpectedNumber
  | T_JSX_TEXT _
  | T_STRING _ -> Error.UnexpectedString
  | T_IDENTIFIER _ -> Error.UnexpectedIdentifier
  | t when token_is_future_reserved t -> Error.UnexpectedReserved
  | t when token_is_strict_reserved t -> Error.StrictReservedWord
  | _ -> Error.UnexpectedToken (value_of_token token)

let error_unexpected env =
  (* So normally we consume the lookahead lex result when Eat.token calls
   * Parser_env.advance, which will add any lexing errors to our list of errors.
   * However, raising an unexpected error for a lookahead is kind of like
   * consuming that token, so we should process any lexing errors before
   * complaining about the unexpected token *)
  error_list env (Peek.errors env);
  error env (get_unexpected_error (Peek.token env))

let error_on_decorators env = List.iter
  (fun decorator -> error_at env ((fst decorator), Error.UnsupportedDecorator))

let strict_error env e = if in_strict_mode env then error env e
let strict_error_at env (loc, e) =
  if in_strict_mode env then error_at env (loc, e)

let function_as_statement_error_at env loc =
  error_at env (loc, Error.FunctionAsStatement {
    in_strict_mode = in_strict_mode env
  })

(* Consume zero or more tokens *)
module Eat = struct
  (* Consume a single token *)
  let token env =
    (* If there's a token_sink, emit the lexed token before moving forward *)
    (match !(env.token_sink) with
      | None -> ()
      | Some token_sink ->
          token_sink {
            token_loc = Peek.loc env;
            token = Peek.token env;
            (**
             * The lex mode is useful because it gives context to some
             * context-sensitive tokens.
             *
             * Some examples of such tokens include:
             *
             * `=>` - Part of an arrow function? or part of a type annotation?
             * `<`  - A less-than? Or an opening to a JSX element?
             * ...etc...
             *)
            token_context=(lex_mode env);
          }
    );

    env.lex_env := Peek.lex_env env;

    error_list env (Peek.errors env);
    comment_list env (Peek.comments env);
    env.last_lex_result := Some (lookahead env);

    Lookahead.junk !(env.lookahead)

  let push_lex_mode env mode =
    env.lex_mode_stack := mode :: !(env.lex_mode_stack);
    env.lookahead := Lookahead.create !(env.lex_env) (lex_mode env)

  let pop_lex_mode env =
    let new_stack = match !(env.lex_mode_stack) with
    | _mode::stack -> stack
    | _ -> failwith "Popping lex mode from empty stack" in
    env.lex_mode_stack := new_stack;
    env.lookahead := Lookahead.create !(env.lex_env) (lex_mode env)

  let double_pop_lex_mode env =
    let new_stack = match !(env.lex_mode_stack) with
    | _::_::stack -> stack
    | _ -> failwith "Popping lex mode from empty stack" in
    env.lex_mode_stack := new_stack;
    env.lookahead := Lookahead.create !(env.lex_env) (lex_mode env)

  (* Semicolon insertion is handled here :(. There seem to be 2 cases where
  * semicolons are inserted. First, if we reach the EOF. Second, if the next
  * token is } or is separated by a LineTerminator.
  *)
  let semicolon env =
    if not (Peek.is_implicit_semicolon env)
    then
      if Peek.token env = Token.T_SEMICOLON
      then token env
      else error_unexpected env
end

module Expect = struct
  let token env t =
    if Peek.token env <> t then error_unexpected env;
    Eat.token env

  let identifier env name =
    begin match Peek.token env with
    | Token.T_IDENTIFIER { raw; _ } when raw = name -> ()
    | _ -> error_unexpected env
    end;
    Eat.token env

  (* If the next token is t, then eat it and return true
   * else return false *)
  let maybe env t =
    if Peek.token env = t
    then begin
      Eat.token env;
      true
    end else false
end

(* This module allows you to try parsing and rollback if you need. This is not
 * cheap and its usage is strongly discouraged *)
module Try = struct
  type 'a parse_result =
    | ParsedSuccessfully of 'a
    | FailedToParse

  exception Rollback

  type saved_state = {
    saved_errors          : (Loc.t * Error.t) list;
    saved_comments        : Ast.Comment.t list;
    saved_last_lex_result : Lex_result.t option;
    saved_lex_mode_stack  : Lex_mode.t list;
    saved_lex_env         : Lex_env.t;
    token_buffer          : ((token_sink_result -> unit) * token_sink_result Queue.t) option;
  }

  let save_state env =
    let token_buffer =
      match !(env.token_sink) with
      | None -> None
      | Some orig_token_sink ->
          let buffer = Queue.create () in
          env.token_sink := Some(fun token_data ->
            Queue.add token_data buffer
          );
          Some(orig_token_sink, buffer)
    in
    {
      saved_errors          = !(env.errors);
      saved_comments        = !(env.comments);
      saved_last_lex_result = !(env.last_lex_result);
      saved_lex_mode_stack  = !(env.lex_mode_stack);
      saved_lex_env         = !(env.lex_env);
      token_buffer;
    }

  let reset_token_sink ~flush env token_buffer_info =
    match token_buffer_info with
    | None -> ()
    | Some(orig_token_sink, token_buffer) ->
        env.token_sink := Some orig_token_sink;
        if flush then Queue.iter orig_token_sink token_buffer

  let rollback_state env saved_state =
    reset_token_sink ~flush:false env saved_state.token_buffer;
    env.errors := saved_state.saved_errors;
    env.comments := saved_state.saved_comments;
    env.last_lex_result := saved_state.saved_last_lex_result;
    env.lex_mode_stack := saved_state.saved_lex_mode_stack;
    env.lex_env := saved_state.saved_lex_env;
    env.lookahead := Lookahead.create !(env.lex_env) (lex_mode env);

    FailedToParse

  let success env saved_state result =
    reset_token_sink ~flush:true env saved_state.token_buffer;
    ParsedSuccessfully result

  let to_parse env parse =
    let saved_state = save_state env in
    try success env saved_state (parse env)
    with Rollback -> rollback_state env saved_state
end
