open Core.Std

module Q : sig
  (** [shell_escape s] can be used as a part of bash command line to mean the word [s]
      with any special characters escaped. *)
  val shell_escape : string -> string
  (** [shell_escape_list l] constructs a part of bash command line with multiple
      blank-separated words [l] on it with any special characters escaped *)
  val shell_escape_list : string list -> string
end

val pretty_span : Time.Span.t -> string
val parse_pretty_span : string -> Time.Span.t

module Start : sig
  type t [@@deriving sexp_of]
  val create :
    need:string ->
    where:string ->
    prog:string ->
    args:string list ->
    t
end

type t [@@deriving sexp_of, bin_io]

val create :
  Start.t ->
  outcome:[`success | `error of string] ->
  duration:Time.Span.t ->
  stdout:string ->
  stderr:string ->
  t

val outcome : t -> [`success | `error of string]

val to_lines : t -> string list

val iter_lines : t -> f:(string -> unit) -> unit
