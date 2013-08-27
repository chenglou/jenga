
open Core.Std
open No_polymorphic_compare let _ = _squelch_unused_module_warning_
open Async.Std

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

  let to_string t = sprintf "(cd %s; %s %s)"
    (Path.to_string t.dir) t.prog (concat_args_quoting_spaces t.args)

end

module Iaction = struct

  type t = {
    tag : Sexp.t;
    func : (unit -> unit Deferred.t);
  } with fields

  let create ~tag ~func = { tag; func; }

end

module Action = struct

  type t = X of Xaction.t | I of Iaction.t

  let case = function
    | X x -> `xaction x
    | I i -> `iaction i

  let shell ~dir ~prog ~args = X (Xaction.shell ~dir ~prog ~args)
  let internal ~tag ~func = I (Iaction.create ~tag ~func)

  (* non primitive *)

  let bash ~dir command_string =
    shell ~dir ~prog:"bash" ~args:["-c"; command_string]

  let write_string string ~target = (* should be build in *)
    bash ~dir:(Path.dirname target) (
      (* quotes wont work if string contains quotes *)
      sprintf "echo '%s' > %s" string (Path.basename target)
    )

end


module Dep1 = struct

  module T = struct

    type t = [
    | `path of Path.t
    | `alias of Alias.t
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
  let absolute ~path = `absolute (Path.Abs.create path)

  let to_string t =
    match t with
    | `path path -> Path.to_string path
    | `alias alias -> Alias.to_string alias
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

end

module Depends = struct

  type _ t =
  | Return : 'a -> 'a t
  | Bind : 'a t * ('a -> 'b t) -> 'b t
  | All : 'a t list -> 'a list t
  | Need : Dep1.t list -> unit t
  | Stdout : Action.t t -> string t (* special -- arg nested in t gives scoping *)
  | Glob : Glob.t -> Path.t list t
  | Deferred : (unit -> 'a Deferred.t) -> 'a t

  let return x = Return x
  let bind t f = Bind (t,f)
  let all ts = All ts
  let dep1s ds = Need ds
  let action_stdout t = Stdout t
  let glob t = Glob t
  let deferred t = Deferred t

  (* non primitive *)

  let map t f = bind t (fun x -> return (f x))
  let all_unit ts = map (all ts) (fun (_:unit list) -> ())

  let ( *>>= ) = bind
  let ( *>>| ) = map

  let path p = dep1s [Dep1.path p]
  let absolute ~path = dep1s [Dep1.absolute ~path]
  let alias a = dep1s [Dep1.alias a]

  let action a = action_stdout a *>>| fun (_:string) -> ()

  let bash ~dir command_string =
    Action.shell ~dir ~prog:"bash" ~args:["-c"; command_string]

  let __contents p =
    action_stdout (
      path p *>>= fun () ->
      return (bash ~dir:(Path.dirname p) (sprintf "cat %s" (Path.basename p)))
    )

  let contents p =
    path p *>>= fun () ->
    deferred (fun () ->
      File_access.enqueue (fun () ->
        Reader.file_contents (Path.to_string p)
      )
    )

  let contents_absolute ~path =
    action_stdout (
      absolute ~path *>>= fun () ->
      return (bash ~dir:Path.the_root (sprintf "cat %s" path))
    )

  let subdirs ~dir =
    glob (Glob.create ~dir ~kinds:(Some [`Directory]) ~glob_string:"*")

  let read_sexp p =
    contents p *>>| fun s ->
    Sexp.scan_sexp (Lexing.from_string s)

  let read_sexps p =
    contents p *>>| fun s ->
    Sexp.scan_sexps (Lexing.from_string s)

end

module Target_rule = struct

  type t = {
    targets : Path.t list;
    action_depends : Action.t Depends.t
  }
  with fields

  let create ~targets action_depends =
    (* Sort targets on construction.
       This allows for better target-rule keyed caching, regarding as equivalent rules
       which differ only in the order of their targets/deps.
    *)
    let targets = List.sort ~cmp:Path.compare targets in
    {
      targets;
      action_depends;
    }

  let head_target_and_rest t =
    match t.targets with
    (* It is possible to construct a rule with an empty list of targets, but once rules
       have been indexed (by target), and a rule obtained by lookup, then we can sure the
       returned rule will have at least one target! *)
    | [] -> assert false
    | x::xs -> x,xs

  let head_target t = fst (head_target_and_rest t)

end

module Rule  = struct

  type t =
  | Target of Target_rule.t
  | Alias of Alias.t * unit Depends.t

  let targets = function
    | Target tr -> Target_rule.targets tr
    | Alias _ -> []

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

  type t = { rules : Rule.t list Depends.t } with fields

  let create rules = { rules }

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
    schemes : (Pattern.t * Rule_scheme.t option) list;
    build_begin : (unit -> unit Deferred.t);
    build_end : (unit -> unit Deferred.t);
  }

  let create
      ?(version=Version.Pre_versioning)
      ?(putenv=[])
      ?command_lookup_path
      ?(build_begin=(fun () -> Deferred.return ()))
      ?(build_end=(fun () -> Deferred.return ()))
      schemes =
    {
      version;
      putenv;
      command_lookup_path;
      schemes =
        List.map schemes ~f:(fun (string,scheme) ->
          Pattern.create_from_glob_string string, scheme
        );
      build_begin;
      build_end;
    }

end
