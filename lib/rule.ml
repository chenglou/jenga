
open Core.Std

let ( *>>| ) = Dep.map

module Target_rule = struct

  type t = {
    targets : Path.Rel.t list;
    action_depends : Action.t Dep.t
  }
  [@@deriving fields, sexp_of]

  let create ~targets action_depends =
    (* Sort targets on construction.
       This allows for better target-rule keyed caching, regarding as equivalent rules
       which differ only in the order of their targets/deps.
    *)
    let targets = List.sort ~cmp:Path.Rel.compare targets in
    match List.find_consecutive_duplicate targets ~equal:Path.Rel.equal with
    | Some (path, _path2) ->
      raise_s [%sexp "duplicate target in rule", (path : Path.Rel.t)]
    | None -> { targets; action_depends }

  let head_target_and_rest t =
    match t.targets with
    (* It is possible to construct a rule with an empty list of targets, but once rules
       have been indexed (by target), and a rule obtained by lookup, then we can sure the
       returned rule will have at least one target! *)
    | [] -> assert false
    | x::xs -> x,xs

  let head_target t = fst (head_target_and_rest t)

end

type t =
| Target of Target_rule.t
| Alias of Alias.t * unit Dep.t
[@@deriving sexp_of]

let targets = function
  | Target tr -> Target_rule.targets tr
  | Alias _ -> []

let alias a deps = Alias (a, Dep.all_unit deps)

let default ~dir deps = alias (Alias.default ~dir) deps

let create ~targets action_depends =
  match
    List.partition_map targets ~f:(fun target ->
      match Path.case target with
      | `absolute abs -> `Fst abs
      | `relative p -> `Snd p)
  with
  | (_ :: _ as abs), _ ->
    raise_s [%sexp "[Rule.create] called with absolute targets",
                              (abs : Path.Abs.t list)]
  | [], targets ->
    Target (Target_rule.create ~targets action_depends)

let simple ~targets ~deps ~action =
  create ~targets (
    Dep.all_unit deps *>>| fun () ->
    action
  )
