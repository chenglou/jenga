
open Core.Std
open No_polymorphic_compare let _ = _squelch_unused_module_warning_
open Async.Std

let (=) = Int.(=)

module Digest = Fs.Digest
module Glob = Fs.Glob

module Alias  = struct

  (* name of an alias target *)
  (* an id which associates to a set of deps
     - bit like an omake phony, but with no action *)

  module T = struct
    type t = {
      dir : Path.t;
      name : string;
    } with sexp, bin_io, compare
    let hash = Hashtbl.hash
  end
  include T
  include Hashable.Make(T)

  let create ~dir name = { dir; name; }
  let split t = t.dir, t.name
  let default ~dir = create ~dir "DEFAULT"

  let to_string t =
    if Path.equal t.dir Path.the_root
    then sprintf ".%s" t.name
    else sprintf "%s/.%s" (Path.to_string t.dir) t.name

  let directory t = t.dir

end

module Scan_id = struct

  module T = struct
    type t = Sexp.t with sexp, bin_io, compare
    let hash = Hashtbl.hash
  end
  include T
  include Hashable.Make(T)

  let of_sexp x = x
  let to_sexp x = x
  let to_string t = Sexp.to_string t

end

module Action_id = struct

  type t = Sexp.t with sexp, bin_io, compare
  let of_sexp x = x
  let to_sexp x = x
  let to_string t = Sexp.to_string t

end

module Goal = struct

  type t = [ `path of Path.t | `alias of Alias.t ] with sexp, bin_io, compare
  let path x = `path x
  let alias x = `alias x
  let case t = t

  let to_string = function
    | `path path -> Path.to_string path
    | `alias alias -> Alias.to_string alias

  let directory = function
    | `path path -> Path.dirname path
    | `alias alias -> Alias.directory alias

end

module Xaction = struct

  type t = {
    dir : Path.t;
    prog : string;
    args : string list;
  } with sexp, bin_io, compare

  let shell ~dir ~prog ~args = { dir ; prog; args; }

  let need_quoting x = String.contains x ' '
  let quote_arg x = if need_quoting x then sprintf "'%s'" x else x
  let concat_args_quoting_spaces xs = String.concat ~sep:" " (List.map xs ~f:quote_arg)

  let to_string t = sprintf "(in dir: %s) %s %s"
    (Path.to_string t.dir) t.prog (concat_args_quoting_spaces t.args)

  let to_script t = sprintf "(cd %s; %s %s)"
    (Path.to_string t.dir) t.prog (concat_args_quoting_spaces t.args)

end


module Action = struct

  module T = struct
    type t = X of Xaction.t | I of Action_id.t
    with sexp, bin_io, compare
    let hash = Hashtbl.hash
  end
  include T
  include Hashable.Make_binable(T)

  let case = function
    | X x -> `xaction x
    | I x -> `id x

  let xaction x = X x
  let internal1 i = I i
  let internal sexp = I (Action_id.of_sexp sexp)

  let shell ~dir ~prog ~args =
    xaction (Xaction.shell ~dir ~prog ~args)

  let to_string = function
    | X x -> Xaction.to_string x
    | I x -> sprintf "INTERNAL:%s"(Action_id.to_string x)

end

module Scanner = struct

  module T = struct

    type t = [
    | `old_internal of Scan_id.t
    | `local_deps of Path.t * Action.t
    ] with sexp, bin_io, compare

    let hash = Hashtbl.hash

  end
  include T
  include Hashable.Make_binable(T)

  let old_internal sexp = `old_internal (Scan_id.of_sexp sexp)
  let local_deps ~dir action = `local_deps (dir,action)

  let to_string = function
    | `old_internal id -> Scan_id.to_string id
    | `local_deps (dir,action) ->
      sprintf "local-deps (deps-wrt: %s): %s"
        (Path.to_string dir) (Action.to_string action)

end

module Dep = struct

  module T = struct

    type t = [
    | `path of Path.t
    | `alias of Alias.t
    | `scan of t list * Scanner.t
    | `glob of Glob.t
    | `absolute of Path.Abs.t
    ]
    with sexp, bin_io, compare
    let hash = Hashtbl.hash
  end
  include T
  include Hashable.Make(T)

  let case t = t
  let path path = `path path
  let alias alias = `alias alias
  let glob glob = `glob glob
  let scanner ts scanner = `scan (ts,scanner)
  let scan1 ts id = `scan (ts,`old_internal id)
  let scan ts sexp = `scan (ts,`old_internal (Scan_id.of_sexp sexp))

  let absolute ~path = `absolute (Path.Abs.create path)

  let rec to_string t =
    match t with
    | `path path -> Path.to_string path
    | `alias alias -> Alias.to_string alias
    | `scan (deps,scanner) ->
      sprintf "scan(: %s) - %s" (String.concat ~sep:" " (List.map deps ~f:to_string))
        (Scanner.to_string scanner)
    | `glob glob -> Fs.Glob.to_string glob
    | `absolute a -> Path.Abs.to_string a

  let default ~dir = alias (Alias.default ~dir)

  let parse_string ~dir string = (* for command-line selection of  top-level demands *)
    (* syntax...
       foo             - target
       path/to/foo     - target
       .foo            - alias
       path/to/.foo    - alias
    *)
    let dir,base =
      match String.rsplit2 string ~on:'/' with
      | None -> dir, string
      | Some (rel_dir_string,base) ->
        match rel_dir_string with
        | "." -> dir,string
        | _ -> Path.relative ~dir rel_dir_string, base
    in
    match String.chop_prefix base ~prefix:"." with
    | None -> path (Path.relative ~dir base)
    | Some after_dot -> alias (Alias.create ~dir after_dot)

  let parse_string_as_deps ~dir string =
    let string = String.tr string ~target:'\n' ~replacement:' ' in
    let words = String.split string ~on:' ' in
    let words = List.filter words ~f:(function | "" -> false | _ -> true) in
    let deps = List.map words ~f:(parse_string ~dir) in
    deps

  let equal t1 t2 = compare t1 t2 = 0

end

module Depends = struct

  type _ t =
  | Return : 'a -> 'a t
  | Bind : 'a t * ('a -> 'b t) -> 'b t
  | All : 'a t list -> 'a list t
  | Need : Dep.t list -> unit t
  | Stdout : Action.t t -> string t

  let return x = Return x
  let bind t f = Bind (t,f)
  let all ts = All ts
  let need d = Need d
  let stdout t = Stdout t

end


module Target_rule = struct

  type t = {
    targets : Path.t list;
    action_depends : Action.t Depends.t
  }
  with fields

  let create_new ~targets action_depends =
    (* Sort targets on construction.
       This allows for better target-rule keyed caching, regarding as equivalent rules
       which differ only in the order of their targets/deps.
    *)
    let targets = List.sort ~cmp:Path.compare targets in
    {
      targets;
      action_depends;
    }

  (* old interface *)
  let create ~targets ~deps ~action =
    create_new ~targets (
      Depends.bind (Depends.need deps) (fun () ->
        Depends.return action
      )
    )

  let head_and_rest_targets t =
    match t.targets with
    (* It is possible to construct a rule with an empty list of targets, but once rules
       have been indexed (by target), and a rule obtained by lookup, then we can sure the
       returned rule will have at least one target! *)
    | [] -> assert false
    | x::xs -> x,xs

  let head_target t = fst (head_and_rest_targets t)

end

module Rule  = struct

  type t = [
  | `target of Target_rule.t
  | `alias of Alias.t * Dep.t list
  ]

  let create ~targets ~deps ~action = `target (Target_rule.create ~targets ~deps ~action)
  let alias alias deps = `alias (alias, deps)
  let default ~dir deps = `alias (Alias.default ~dir, deps)

  let targets = function
    | `target tr -> Target_rule.targets tr
    | `alias _ -> []

  let defines_alias_for a1 = function
    | `target _ -> false
    | `alias (a2,_) -> Alias.compare a1 a2 = 0

  let case t = t

  let create_new ~targets x = `target (Target_rule.create_new ~targets x)

end

module Gen_key = struct

  module T = struct
    type t = {
      tag : string;
      dir : Path.t;
    } with sexp, bin_io, compare
    let hash = Hashtbl.hash
  end
  include T
  include Hashable.Make_binable(T)

  let create ~tag ~dir = { tag; dir; }
  let to_string t = sprintf "%s:%s" t.tag (Path.to_string t.dir)
end

module Rule_generator = struct

  type t = {
    deps:Dep.t list;
    gen:(unit -> Rule.t list Deferred.t);
  }

  let create ~deps ~gen = { deps; gen; }

  let deps t = t.deps

  let gen t =
    t.gen() >>= fun rules ->
    return rules

end

module Rule_scheme = struct

  type t = {
    tag : string;
    body : (dir:Path.t -> Rule_generator.t) ref; (* ref for identity *)
  }
  with fields

  let create ~tag f = {tag; body = ref f;}

end


module Env = struct

  type t = {
    version:Version.t;
    putenv:(string * string) list;
    command_lookup_path : [`Replace of string list | `Extend of string list] option;
    action : Sexp.t -> unit Deferred.t;
    scan : Sexp.t -> Dep.t list Deferred.t;
    schemes : (Pattern.t * Rule_scheme.t option) list;
    build_begin : (unit -> unit Deferred.t);
    build_end : (unit -> unit Deferred.t);
  }

  let k_assert_false = fun _ -> assert false

  let create
      ?(version=Version.Pre_versioning)
      ?(putenv=[]) ?command_lookup_path
      ?(action=k_assert_false) ?(scan=k_assert_false)
      ?(build_begin=(fun () -> Deferred.return ()))
      ?(build_end=(fun () -> Deferred.return ()))
      schemes =
    {
      version;
      putenv;
      command_lookup_path;
      action;
      scan;
      schemes =
        List.map schemes ~f:(fun (string,scheme) ->
          Pattern.create_from_glob_string string, scheme
        );
      build_begin;
      build_end;
    }

end
