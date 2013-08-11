
open Core.Std
open No_polymorphic_compare let _ = _squelch_unused_module_warning_
open Async.Std

open Description

module Path = Path
module Kind = Fs.Kind

module Glob = struct

  include Fs.Glob

  let create ~dir ?kinds glob_string = create ~dir ~kinds ~glob_string

  let exec glob =
    let fs = For_user.fs() in
    Tenacious.exec (Fs.list_glob fs glob) >>| fun (res,_heart) ->
    match res with
    | `listing listing -> Fs.Listing.paths listing
    | _ -> failwith "Glob.exec"

end

module Alias = Alias
module Scanner = Scanner
module Dep = Dep
module Xaction = Xaction
module Action = Action
module Depends = Depends
module Rule = Rule
module Rule_scheme = Rule_scheme
module Rule_generator = Rule_generator
module Env = Env
module Version = Version

let verbose() = Config.verbose (For_user.config ())

let load_sexp_for_jenga = For_user.load_sexp_for_jenga
let load_sexps_for_jenga = For_user.load_sexps_for_jenga

module Raw_sexp_makefile_rule = struct

  type t = string list with sexp

  let load_many path =
    For_user.load_sexps_for_jenga t_of_sexp path

  let split_list_at_colons =
    let rec loop acc xs  =
      let front,xs = List.split_while xs ~f:(fun s -> not (String.equal ":" s)) in
      let acc = front :: acc in
      match xs with
      | [] -> List.rev acc
      | colon::xs -> assert (String.equal colon ":"); loop acc xs
    in
    loop []

  let convert_to_rule ~dir xs =
    let path_of_string string = Path.relative ~dir string in
    let dep_of_string string = Dep.parse_string ~dir string in
    let xss = split_list_at_colons xs in
    let err s = failwith s in
    match xss with
    | [] | [_] ->
      err "a rule must contain 1 or 2 colons, found none"
    | _::_::_::_::_ ->
      err (sprintf "a rule must contain 1 or 2 colons, found %d"
             (List.length xss - 1))
    | [[alias];deps] ->
      Rule.alias (Alias.create ~dir alias) (List.map deps ~f:dep_of_string)
    | [_;_] ->
      err "an alias definition must contain exactly 1 target"
    | [_;_;[]]  ->
      err "a rule action must have at least 1 word"
    | [targets;deps;(prog::args)] ->
      Rule.create
        ~targets:   (List.map targets ~f:path_of_string)
        ~deps:      (List.map deps ~f:dep_of_string)
        ~action:    (Action.shell ~dir ~prog ~args)

end

let parse_rules_from_simple_makefile path =
  let dir = Path.dirname path in
  Raw_sexp_makefile_rule.load_many path >>= fun xs ->
  let rules = List.map xs ~f:(Raw_sexp_makefile_rule.convert_to_rule ~dir) in
  let default_explicitly_defined =
    List.exists rules ~f:(Rule.defines_alias_for (Alias.default ~dir))
  in
  if default_explicitly_defined
  then return rules
  else
    match rules with
    | [] -> return rules
    | rule1::_ ->
      let targets = Rule.targets rule1 in
      let implicit_default_rule = Rule.default ~dir (List.map targets ~f:Dep.path) in
      return (implicit_default_rule :: rules)



exception Run_now_of_internal_action_not_supported of Action_id.t
exception Non_zero_status_from_action_run_now of Action.t


let run_action_now_output ~output action =
  match Action.case action with
  | `id id -> raise (Run_now_of_internal_action_not_supported id)
  | `xaction xaction ->
    let config = For_user.config() in
    let need = "run_now" in
    let rel_path_semantics = Forker.Rel_path_semantics.New_wrt_working_dir in
    let putenv = [] in
    Job.run ~config ~need ~rel_path_semantics ~putenv ~xaction ~output >>= function
    | Error `non_zero_status     -> raise (Non_zero_status_from_action_run_now action)
    | Error (`other_error exn)   -> raise exn
    | Ok x                       -> Deferred.return x


let run_action_now =
  run_action_now_output ~output:Job.Output.ignore

let run_action_now_stdout =
  run_action_now_output ~output:Job.Output.stdout


let enqueue_file_access = File_access.enqueue
