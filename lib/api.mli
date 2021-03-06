
(* Jenga API - Monadic Style.
   This signature provides the interface between the `user-code' which
   describes the build rules etc for a specific instatnce of jenga,
   and the core jenga build system. *)

open! Core.Std
open! Async.Std

module Path : sig

  (** Path.t can be thought of as [`abs of string list | `rel of string list]
      with absolute paths [`abs l] referring to the unix path reachable by
      following path compoments in [l] starting from the root ("/")
      and [`rel l] referring to the path relative to the jenga root.

      Character '/' is disallowed in path components.
      Path components "" and "."  and ".." are disallowed and if used are simplified out.
  *)
  type t [@@deriving sexp]
  include Comparable.S with type t := t
  include Hashable.S with type t := t

  (** an absolute path made from a /-separated path string.
      the string must start with a '/' *)
  val absolute : string -> t

  (** a relative path made from a /-separated path string.
      the string must NOT start with a '/' *)
  val relative : dir:t -> string -> t

  (** either absolute or relative taken w.r.t. [dir] - determined by leading char *)
  val relative_or_absolute : dir:t -> string -> t

  (** if relative, displayed as repo-root-relative string.
      [relative_or_absolute ~dir:the_root (to_string t) = t] *)
  val to_string : t -> string

  (** refers to the jenga repo root *)
  val the_root : t

  (** refers to the root of the unix filesystem *)
  val unix_root : t

  (** path with the last path component dropped.
      for the roots ([the_root] or [unix_root])
      [dirname x = x] *)
  val dirname : t -> t

  (** last component of the path.
      for the roots we have [basename x = "."] *)
  val basename : t -> string

  (** shortcut for [relative ~dir:the_root] *)
  val root_relative : string -> t

  (** [is_descendant ~dir t = true] iff there exists a ".."-free [x] such that
      [relative ~dir x = t] *)
  val is_descendant : dir:t -> t -> bool

  (** [x = reach_from ~dir t] is such that [relative_or_absolute ~dir x = t],
     x starts with a "." or a '/', and x is otherwise as short as possible *)
  val reach_from : dir:t -> t -> string

  (** returns absolute path string, even if the path is relative.
      depends on jenga repo location. *)
  val to_absolute_string : t -> string

end

module Kind : sig
  type t = [ `File | `Directory | `Char | `Block | `Link | `Fifo | `Socket ]
  [@@deriving sexp_of]
end

module Glob : sig
  type t [@@deriving sexp]
  (** [create ~dir pattern] refers to anything in [dir] whose basename matches
      the [pattern]. Note that patterns with slashes or path globs (**) in them
      do not work.
      Special syntax allowed in [pattern]:
      * - stands for any string unless it's the leading character, in which case it
      does not match empty string or hidden files (prefixed with a dot).
      ? - stands for any character
      [a-z] - a character in range ['a' .. 'z']
      [!a-z] - a character out of ['a' .. 'z']
      \ - escapes the character following it
      {alt1,alt2} - matches both alt1 and alt2. can be nested.
  *)
  val create : dir:Path.t -> ?kinds: Kind.t list -> string -> t
  (** matches exactly the filename given *)
  val create_from_path : kinds:Fs.Kind.t list option -> Path.t -> t
end

module Alias : sig
  type t [@@deriving sexp]
  val create : dir: Path.t -> string -> t
end

module Action : sig
  type t [@@deriving sexp_of]
  (** [process ?ignore_stderr ~dir ~prog ~args] - constructs an action, that when run
      causes a new process to be created to run [prog], passing [args], in [dir].
      The process fails if its exit code is not zero, or if print things on stderr
      (unless ~ignore_stderr:true is passed).*)
  val process
    : ?ignore_stderr:bool
    -> dir:Path.t
    -> prog:string
    -> args:string list
    -> unit
    -> t
  val save : ?chmod_x:unit -> string -> target:Path.t -> t
end

module Shell : sig

  (* [Shell.escape arg] quotes a string (if necessary) to avoid interpretation of
     characters which are special to the shell.

     [Shell.escape] is used internally by jenga when displaying the "+" output lines,
     which show what commands are run; seen by the user when running [jenga -verbose] or
     if the command results in a non-zero exit code. It is exposed in the API since it is
     useful when constructing actions such as: [Action.progress ~dir ~prog:"bash" ~args],
     which should ensure [args] are suitably quoted.

     Examples:
     (1) escape "hello" -> "hello"
     (2) escape "foo bar" -> "'foo bar'"
     (3) escape "foo'bar" -> "'foo'\\''bar'"

     Note the [arg] and result strings in the above examples are expressed using ocaml
     string literal syntax; in particular, there is only single backslash in the result of
     example 3.

     Example (1): No quoting is necessary.  Example (2): simple single quoting is used,
     since [arg] contains a space, which is special to the shell.  Example (3): the result
     is single quoted; the embedded single quote is handled by: un-quoting, quoting using
     a bashslash, then re-quoting.
  *)
  val escape : string -> string

end

module Var : sig

  (** [Var.t] is a registered environment variable. It's value value may be queried and
      modified via the jenga RPC or command line. *)
  type 'a t

  (** [register name ?choices] registers [name].  If [choices] is provided, this is
      attached as meta information, available when querying.

      [register_with_default ?default name ?choices] is like [register] except [default]
      is used when the variable is unset, and is also attached as meta information.

      Except for the registration of [default] as meta-info, [register_with_default]
      behaves as: [register ?choices name |> map ~f:(Option.value ~default)]

      An exception is raised if the same name is registered more than once in a reload of
      the jengaroot.
  *)
  val register              : ?choices:string list -> string                   -> string option t
  val register_with_default : ?choices:string list -> string -> default:string -> string t

  (** [peek t] causes modification to [t] (via RPC or command-line) to trigger a reload of
      the jengaroot. To avoid this use [Dep.getenv] instead. *)
   val peek : ?dont_trigger:unit -> 'a t -> 'a

  val map  : 'a t -> f:('a -> 'b) -> 'b t

end

module Dep : sig (* The jenga monad *)

  type 'a t [@@deriving sexp_of]
  val return : 'a -> 'a t
  val bind : 'a t -> ('a -> 'b t) -> 'b t
  val map : 'a t -> ('a -> 'b) -> 'b t
  val both : 'a t -> 'b t -> ('a * 'b) t
  val all : 'a t list -> 'a list t
  val all_unit : unit t list -> unit t
  val cutoff : equal:('a -> 'a -> bool) -> 'a t -> 'a t
  val deferred : (unit -> 'a Deferred.t) -> 'a t

  val action : Action.t t -> unit t
  val action_stdout : Action.t t -> string t
  val alias : Alias.t -> unit t
  val path : Path.t -> unit t

  (** [getenv v] provides access to a registered environment variable, responding to
      changes notified to jenga via the [setenv] RPC/command-line. *)
  val getenv : 'a Var.t -> 'a t

  (** [group_dependencies t] is equivalent to [t], however jenga will be careful to avoid
      duplicating the set of dependencies that have been declared. This is best used under
      an alias, as the alias will allow to share the computation as well. *)
  val group_dependencies : 'a t -> 'a t

  (* [source_if_it_exists] Dont treat path as a goal (i.e. don't force it to be built)
     Just depend on its contents, if it exists. It's ok if it doesn't exist. *)
  val source_if_it_exists : Path.t -> unit t

  val contents : Path.t -> string t
  val contents_cutoff : Path.t -> string t

  (* The semantics of [glob_listing] and [glob_change] includes files which exist on the
     file-system AND files which are buildable by some jenga rule *)
  val glob_listing : Glob.t -> Path.t list t
  val glob_change : Glob.t -> unit t

  (* Versions with old semantics: only includes files on the file-system. *)
  val fs_glob_listing : Glob.t -> Path.t list t
  val fs_glob_change : Glob.t -> unit t

  val subdirs : dir:Path.t -> Path.t list t
  (** [file_exists] makes the information about file existence available to the rules, but
      does not declare it as an action dependency.
  *)
  val file_exists : Path.t -> bool t
  (** [file_existence] declares an action dependency on file existence *)
  val file_existence : Path.t -> unit t

  module List : sig
    val concat_map : 'a list -> f:('a -> 'b list t) -> 'b list t
    val concat : 'a list t list -> 'a list t
  end

  val buildable_targets : dir:Path.t -> Path.t list t

  (* [source_files ~dir]
     files_on_filesystem ~dir \ buildable_targets ~dir
  *)
  val source_files : dir:Path.t -> Path.t list t

end

module Reflected : sig
  module Action : sig
    type t [@@deriving sexp_of]
    val dir : t -> Path.t
    val to_sh_ignoring_dir : t -> string
    val string_for_one_line_make_recipe_ignoring_dir : t -> string
  end
  (* simple make-style rule triple, named [Trip.t] to distinguish from
     Jenga's more powerful rules [Rule.t] below. *)
  module Trip : sig
    type t = {
      targets: Path.t list;
      deps : Path.t list;
      action : Action.t;
    }
    [@@deriving sexp_of]
  end
end

module Reflect : sig

  val alias : Alias.t -> Path.t list Dep.t
  val path : Path.t -> Reflected.Trip.t option Dep.t

  val reachable :
    keep:(Path.t -> bool) ->
    ?stop:(Path.t -> bool) -> (* defaults to: !keep *)
    Path.t list ->
    Reflected.Trip.t list Dep.t

  val putenv : (string * string option) list Dep.t

end

module Rule : sig
  type t [@@deriving sexp_of]
  val create : targets:Path.t list -> Action.t Dep.t -> t
  val alias : Alias.t -> unit Dep.t list -> t
  val default : dir:Path.t -> unit Dep.t list -> t
  val simple : targets:Path.t list -> deps:unit Dep.t list -> action:Action.t -> t
end

module Scheme : sig
  type t [@@deriving sexp_of]
  val rules : Rule.t list -> t
  val dep : t Dep.t -> t
  val all : t list -> t
  val exclude : (Path.t -> bool) -> t -> t
  val rules_dep : Rule.t list Dep.t -> t
  val contents : Path.t -> (string -> t)-> t
  val no_rules : t
end

module Env : sig
  type t = Env.t
  val create :
    ?putenv:(string * string option) list ->
    ?command_lookup_path:[`Replace of string list | `Extend of string list] ->
    ?build_begin : (unit -> unit Deferred.t) ->
    ?build_end : (unit -> unit Deferred.t) ->

    (* [create ~artifacts ...]

       Optional [artifacts] allows specification, on a per-directory basis, which paths
       are to be regarded as artifacts, and hence become candidates for deletion as
       stale-artifacts, if there is no build rule.

       If [artifacts] is not provided, jenga will determine artifacts using it's own
       knowledge of what was previously built, as recorded in .jenga/db. *)
    ?artifacts: (dir:Path.t -> Path.t list Dep.t) ->

    (* [create f] - Mandatory argument [f] specifies, per-directory, the rule-scheme. *)
    (dir:Path.t -> Scheme.t) ->
    t

end

(* The jenga API intentionally shadows printf, so that if opened in jenga/root.ml the
   default behaviour is for [printf] to print via jenga's message system, and not
   directly to stdout. Sending to stdout makes no sense for a dameonized jenga server.

   [printf] sends messages via jenga's own message system, (i.e. not directly to stdout).
   Messages are logged, transmitted to jenga [trace] clients, and displayed to stdout if
   the jenga server is not running as a daemon.

   [printf_verbose] is like [printf], except the message are tagged as `verbose', so
   allowing non-verbose clients to mask the message

   There is no need to append a \n to the string passed to [printf] or [printf_verbose].
*)

val printf : ('a, unit, string, unit) format4 -> 'a
val printf_verbose : ('a, unit, string, unit) format4 -> 'a

val run_action_now : Action.t -> unit Deferred.t
val run_action_now_stdout : Action.t -> string Deferred.t
