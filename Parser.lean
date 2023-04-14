import Lean
import Lean.Environment
import Lean.Elab.Frontend
import Lean.Elab.InfoTree
import Lean.Data.Options
import Mathlib.Tactic.Linarith

open Lean
open Lean Elab
open Lean Meta
open Lean.Elab.Tactic

def solvedEmoji := "✅"

partial def findSubFrames (ctx: ContextInfo) (infoTree : InfoTree) :=
  (InfoTree.context ctx infoTree).deepestNodes fun _ i _ =>
    match i with
    | .ofTermInfo _ => some s!"{i.stx.prettyPrint}"
    | _ => none 

structure Frame where
  fromType: String
  toType: String
  action: String
  subFrames : List String

structure LetDefn where
  name : String
  defn: String

structure TreeState where
  types : PersistentHashMap String String 
  frames : List Frame
  defns : List LetDefn
  deriving Inhabited

abbrev FrameStack T := StateT TreeState IO T

def addFrame (frame : Frame) : FrameStack Unit :=
  modify fun state => {state with frames := frame :: state.frames }

def addDefn (name defn : Format) : FrameStack Unit :=
  modify fun state => {state with defns := {name := name.pretty, defn := defn.pretty} :: state.defns }

def addName (name type : Format) : FrameStack Unit :=
  modify fun state => {state with types := state.types.insert name.pretty type.pretty }

def getFirstGoal (goals : List MVarId) (mctx : MetavarContext) : Option MetavarDecl :=
  goals.map mctx.findDecl? |>.findSome? id

def getPPContext (ctx: ContextInfo) (goals: List MVarId) (mctx : MetavarContext) : PPContext :=
  let decl := getFirstGoal goals mctx
  ctx.toPPContext (if let some mDecl := decl then mDecl.lctx else {})

def getGoalType (ppContext: PPContext) (goals : List MVarId) (mctx : MetavarContext) : IO String :=
  if let some mDecl := getFirstGoal goals mctx then
    return (← ppExprWithInfos ppContext mDecl.type).fmt.pretty
  else pure solvedEmoji

def parseTacticProof (infoTree : InfoTree) : FrameStack Unit :=
  infoTree.visitM' fun (ctx : ContextInfo) (i: Info) (children : PersistentArray InfoTree) => do
    if let .ofTacticInfo tInfo := i then
      let ppContext := if tInfo.goalsAfter.length > 0 then
         getPPContext ctx tInfo.goalsAfter tInfo.mctxAfter else
         getPPContext ctx tInfo.goalsBefore tInfo.mctxBefore 

      -- Record the edge from the goal before the tactic to the goal after the tactic
      let addGoalChangeFrame : FrameStack Unit := do
        let fromType ← getGoalType ppContext tInfo.goalsBefore tInfo.mctxBefore
        let toType ← getGoalType ppContext tInfo.goalsAfter tInfo.mctxAfter
        addFrame {fromType,
                  toType,
                  action := s!"{tInfo.stx.prettyPrint}",
                  subFrames := children.map (findSubFrames ctx) |>.toList.join}

      match tInfo.stx with
      | `(tactic| let $name := $defn) =>
        addDefn (← ppTerm ppContext name) (← ppTerm ppContext defn)

      | `(tactic| have $name : $type := by $_) =>
        addName (← ppTerm ppContext name) (← ppTerm ppContext type)

      | `(tactic| have $name : $type := $defn) =>
        let name ← ppTerm ppContext name
        let type ← ppTerm ppContext type
        addName name type
        -- Add an artificial edge for the let definition into term if it wasn't defined via `by` like it was via an `by exact`
        let t := {fromType := type.pretty,
                  toType := solvedEmoji,
                  action:= s!"exact {← ppTerm ppContext defn}",
                  subFrames := children.map (findSubFrames ctx) |>.toList.join |>.filter (· != name.pretty)}
        addFrame t

      | `(tactic| intro $name:ident) =>
        let mDecl := getFirstGoal tInfo.goalsAfter tInfo.mctxAfter |>.get!
        if let some decl := mDecl.lctx.findFromUserName? name.getId then
          addName (← ppTerm ppContext name) (← ppExprWithInfos ppContext decl.type).fmt
        addGoalChangeFrame

      | `(tactic| apply $_)
      | `(tactic| exact $_)
      | `(tactic| refine $_)
      | `(tactic| linarith $_) =>
        addGoalChangeFrame

      | _ => pure ()