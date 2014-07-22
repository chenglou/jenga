
open Core.Std
open Async.Std

module Persist : sig
  type t with sexp, bin_io
  val create : unit -> t
end

module Jr_spec : sig
  type t
  val in_root_dir : t
  val path : Path.t -> t
end

val build_forever :
  Config.t ->
  Progress.t ->
  jr_spec: Jr_spec.t ->
  top_level_demands : Goal.t list ->
  Fs.t ->
  Persist.t ->
  when_polling:(unit -> unit Deferred.t) ->
  when_rebuilding:(unit -> unit Deferred.t) ->
  unit Deferred.t

val exit_code_upon_control_c : int ref

val path_locked : Path.Rel.t -> bool
