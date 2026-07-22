(* verification/formal/koika/FluxMem.v
 *
 * A word-granular magic-memory LEAF module (a primitive Sem.t, exactly like
 * Gpu's Reg / FIFOF / BRAM leaves): combinational read, single write port,
 * state = a total function from 32-bit (aligned) addresses to words.
 *
 * This models the data memory the way BSV's RegFile/mkRAM primitives model
 * storage: the leaf's semantics is the trusted primitive contract, the logic
 * AROUND it (address computation, load/store sequencing, byte lanes) is what
 * the refinement proves.  A BRAM-latency version (req/resp, as in Gpu.BRAM)
 * is the later upgrade path for the pipelined machine.
 *)

From Koika Require Import Prelude.
From Flux Require Import FluxCommon.

#[local] Set Default Timeout 120.

Variant mem_vmet_t :=
  | rdMem
.

Variant mem_amet_t :=
  | wrMem
.

Definition rdMem_sig : Methods.sig :=
  {| Methods.a := [32]; Methods.r := 32 |}.
Definition wrMem_sig : Methods.sig :=
  {| Methods.a := [32; 32]; Methods.r := 0 |}.

Module WordMem. Section WordMem.

  #[export] Instance VMets : Methods.t mem_vmet_t :=
  {|
    Methods.met_list := [rdMem];
    Methods.get_sig met :=
      match met with
      | rdMem => rdMem_sig
      end;
    Methods.get_name met :=
      match met with
      | rdMem => "rdMem"
      end;
  |}.

  #[export] Instance AMets : Methods.t mem_amet_t :=
  {|
    Methods.met_list := [wrMem];
    Methods.get_sig met :=
      match met with
      | wrMem => wrMem_sig
      end;
    Methods.get_name met :=
      match met with
      | wrMem => "wrMem"
      end;
  |}.

  Definition ifc := Modules.mkInterface _ _ VMets AMets.

End WordMem. End WordMem.

(* Memory state and its update — shared verbatim by the leaf semantics and by
   the ISA spec machine, so the coupling is definitional. *)
Definition MemState := Word -> Word.

Definition mem_upd (m : MemState) (a v : Word) : MemState :=
  fun x => if eq_dec x a then v else m x.

Definition rdMem_spec : Sem.v rdMem_sig MemState :=
  fun args st ret => ret = st (chd args)
.

Definition wrMem_spec : Sem.a wrMem_sig MemState :=
  fun args st _ret st' => st' = mem_upd st (chd args) (chd (ctl args))
.

Definition mkWordMem : Sem.t WordMem.ifc :=
{|
  Sem.state_t := MemState;
  Sem.init := fun _ => Bits.zero;
  Sem.rules := Rules.empty;
  Sem.vmet_sem (v : Modules.vmet_t WordMem.ifc) :=
    match v with
    | rdMem => rdMem_spec
    end;
  Sem.amet_sem a :=
    match a with
    | wrMem => wrMem_spec
    end;
  Sem.rule_sem r := False_rect _ r;
|}.

(* ---------------------------------------------------------------------------
   BramWordMem — the req/resp BRAM-latency leaf this file's header always
   anticipated ("as in Gpu.BRAM"): the memory primitive for the PIPELINED
   machine, matching the RTL bram_dmem contract (address registered at one
   step, data available at the next).

   State = (memory, pending read address). Semantics:
     reqRd  a     — register a read address (a fresh request overwrites any
                    pending one, exactly as re-registering a BRAM address).
     respRd -> v  — return mem[pending]; REFUSES (relation is empty) when no
                    request is pending, so a schedule can only consume a
                    response one step after issuing its request.
     wrMem  a v   — write through to the array; pending is unaffected (the
                    RTL BRAM's read and write ports are independent).

   The transactional FluxCoreImpl keeps using WordMem (combinational read) —
   this leaf is compiled and trusted now so the pipelined Impl builds on a
   frozen primitive, not a moving one.
   ------------------------------------------------------------------------- *)

Variant bmem_vmet_t :=
  | respRd
.

Variant bmem_amet_t :=
  | breqRd
  | bwrMem
.

Definition respRd_sig : Methods.sig :=
  {| Methods.a := []; Methods.r := 32 |}.
Definition breqRd_sig : Methods.sig :=
  {| Methods.a := [32]; Methods.r := 0 |}.

Module BramWordMem. Section BramWordMem.

  #[export] Instance VMets : Methods.t bmem_vmet_t :=
  {|
    Methods.met_list := [respRd];
    Methods.get_sig met :=
      match met with
      | respRd => respRd_sig
      end;
    Methods.get_name met :=
      match met with
      | respRd => "respRd"
      end;
  |}.

  #[export] Instance AMets : Methods.t bmem_amet_t :=
  {|
    Methods.met_list := [breqRd; bwrMem];
    Methods.get_sig met :=
      match met with
      | breqRd => breqRd_sig
      | bwrMem => wrMem_sig
      end;
    Methods.get_name met :=
      match met with
      | breqRd => "reqRd"
      | bwrMem => "wrMem"
      end;
  |}.

  Definition ifc := Modules.mkInterface _ _ VMets AMets.

End BramWordMem. End BramWordMem.

Definition BramState := (MemState * option Word)%type.

Definition respRd_spec : Sem.v respRd_sig BramState :=
  fun _args st ret =>
    match snd st with
    | Some a => ret = fst st a
    | None   => False        (* no pending request: the method refuses *)
    end
.

Definition breqRd_spec : Sem.a breqRd_sig BramState :=
  fun args st _ret st' => st' = (fst st, Some (chd args))
.

Definition bwrMem_spec : Sem.a wrMem_sig BramState :=
  fun args st _ret st' =>
    st' = (mem_upd (fst st) (chd args) (chd (ctl args)), snd st)
.

Definition mkBramWordMem : Sem.t BramWordMem.ifc :=
{|
  Sem.state_t := BramState;
  Sem.init := (fun _ => Bits.zero, None);
  Sem.rules := Rules.empty;
  Sem.vmet_sem (v : Modules.vmet_t BramWordMem.ifc) :=
    match v with
    | respRd => respRd_spec
    end;
  Sem.amet_sem a :=
    match a with
    | breqRd => breqRd_spec
    | bwrMem => bwrMem_spec
    end;
  Sem.rule_sem r := False_rect _ r;
|}.
