"""Low-Level Intermediate Representation (LIR) and AST Visitor for MLP-EngineV2.

Defines structured AST nodes for C declarations, statements, expressions, and
MLP_V2_ACCELERATOR hardware intrinsics, along with a tree-visiting C code emitter
(`CCodeEmitter`) that formats LIR trees into valid C99 source without string templates.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional, Sequence, Tuple, Union


# =============================================================================
# 1. Expression Nodes (LIR Expr)
# =============================================================================

class Expr:
    """Base class for all Low-Level IR expressions."""


@dataclass(frozen=True)
class IntImm(Expr):
    """Integer immediate constant (decimal or hexadecimal)."""

    value: int
    hex_width: int = 0
    unsigned: bool = False


@dataclass(frozen=True)
class VarRef(Expr):
    """Variable or symbolic constant identifier."""

    name: str


@dataclass(frozen=True)
class UnaryOp(Expr):
    """Unary operation (e.g. `-x`, `~x`, `--x`, `++x`)."""

    op: str
    operand: Expr
    postfix: bool = False


@dataclass(frozen=True)
class BinaryOp(Expr):
    """Binary operation (e.g. `a + b`, `x << 8`, `a | b`)."""

    op: str
    left: Expr
    right: Expr


@dataclass(frozen=True)
class TernaryOp(Expr):
    """Conditional expression `cond ? true_expr : false_expr`."""

    cond: Expr
    true_expr: Expr
    false_expr: Expr


@dataclass(frozen=True)
class Subscript(Expr):
    """Array subscript `base[index]`."""

    base: Expr
    index: Expr


@dataclass(frozen=True)
class CastExpr(Expr):
    """C type cast `(c_type)expr`."""

    c_type: str
    expr: Expr


@dataclass(frozen=True)
class CallExpr(Expr):
    """Function or macro call `func(arg0, arg1, ...)`."""

    func: str
    args: Tuple[Expr, ...] = ()


# =============================================================================
# 2. Statement & Hardware Intrinsic Nodes (LIR Stmt)
# =============================================================================

class Stmt:
    """Base class for all Low-Level IR statements."""


@dataclass
class CommentStmt(Stmt):
    """Single-line comment in the IR."""

    text: str


@dataclass
class VarDeclStmt(Stmt):
    """Local variable declaration `c_type name = init;`."""

    c_type: str
    name: str
    init: Optional[Expr] = None


@dataclass
class AssignStmt(Stmt):
    """Assignment statement `target op value;` (`=`, `+=`, `|=`, `^=`)."""

    target: Expr
    value: Expr
    op: str = "="


@dataclass
class ExprStmt(Stmt):
    """Standalone expression statement `expr;`."""

    expr: Expr


@dataclass
class IfStmt(Stmt):
    """Conditional branch `if (cond) { then_body } else { else_body }`."""

    cond: Expr
    then_body: List[Stmt] = field(default_factory=list)
    else_body: Optional[List[Stmt]] = None


@dataclass
class ForStmt(Stmt):
    """Structured loop `for (init_type loop_var = start; cond; step_var step_op step_val) { body }`."""

    init_type: str
    loop_var: str
    start: Expr
    cond: Expr
    step_op: str
    step_val: Expr
    body: List[Stmt] = field(default_factory=list)
    extra_steps: List[Tuple[str, str, Expr]] = field(default_factory=list)


@dataclass
class ReturnStmt(Stmt):
    """Function return `return value;`."""

    value: Expr


@dataclass
class BreakStmt(Stmt):
    """Loop break `break;`."""


# --- MLP_V2_ACCELERATOR Hardware Intrinsic IR Nodes ---

@dataclass
class AccCfgStmt(Stmt):
    """Hardware `ACC.CFG` instruction (`cfg[field] = value`)."""

    field: str
    value: Expr


@dataclass
class AccLoadStmt(Stmt):
    """Hardware `ACC.LOAD` instruction (`acc_load(bank)`)."""

    bank: Expr


@dataclass
class AccRunStmt(Stmt):
    """Hardware `ACC.RUN` instruction (`acc_run(bank, flags)`)."""

    bank: Expr
    flags: Expr


@dataclass
class AccStoreStmt(Stmt):
    """Hardware `ACC.STORE` instruction (`acc_store()`)."""


@dataclass
class AccWaitStmt(Stmt):
    """Hardware `ACC.WAIT` instruction (`acc_wait(mask)`)."""

    mask: str


@dataclass
class AccCheckErrStmt(Stmt):
    """Hardware `ACC.STATUS` error check (`if (acc_status() >> 16) return err_code;`)."""

    err_code: int = -1


@dataclass
class CsrReadStmt(Stmt):
    """RISC-V CSR read instruction (`csrrs dst, csr, x0`)."""

    csr_name: str
    dst_var: str


@dataclass
class WriteTestbenchRegStmt(Stmt):
    """Write progress/metric value to RISC-V GPR (`x25`..`x31`) monitored by `CORE_TB`."""

    reg_name: str
    value: Expr


# =============================================================================
# 3. Top-Level Declarations & Translation Units (LIR Decl)
# =============================================================================

class TopDecl:
    """Base class for top-level declarations and preprocessor directives."""


@dataclass
class IncludeDecl(TopDecl):
    """`#include <header>` or `#include "header"`."""

    header: str
    system: bool = False


@dataclass
class DefineDecl(TopDecl):
    """`#define NAME VALUE`."""

    name: str
    value: Union[Expr, str]
    comment: Optional[str] = None


@dataclass
class StaticArrayDecl(TopDecl):
    """Static memory buffer `static c_type name[size] attr;`."""

    c_type: str
    name: str
    size: int
    attr: str = "NOINIT"


@dataclass
class RawDecl(TopDecl):
    """Raw C declaration emitted verbatim (no LIR lowering)."""

    text: str
    comment: Optional[str] = None


@dataclass
class ParamDecl:
    """Function parameter `c_type name`."""

    c_type: str
    name: str


@dataclass
class FunctionDecl(TopDecl):
    """C function definition synthesized by the compiler."""

    return_type: str
    name: str
    params: List[ParamDecl]
    body: List[Stmt]
    is_static: bool = True
    is_inline: bool = False
    doc_comment: Optional[str] = None


@dataclass
class HeaderUnit:
    """Complete AST for a generated C header file (`.h`)."""

    guard_macro: str
    banner_lines: List[str]
    decls: List[TopDecl]


@dataclass
class SourceUnit:
    """Complete AST for a generated C source file (`.c`)."""

    banner_lines: List[str]
    decls: List[TopDecl]


# =============================================================================
# 4. Pure AST-Visiting C Code Emitter
# =============================================================================

_PRECEDENCE = {
    "|": 1,
    "^": 2,
    "&": 3,
    "==": 4,
    "!=": 4,
    "<": 5,
    "<=": 5,
    ">": 5,
    ">=": 5,
    "<<": 6,
    ">>": 6,
    "+": 7,
    "-": 7,
    "*": 8,
    "/": 8,
    "%": 8,
}


class CCodeEmitter:
    """Tree visitor that lowers `HeaderUnit` and `SourceUnit` ASTs into C99 code."""

    def __init__(self, indent_str: str = "    ") -> None:
        self.indent_str = indent_str

    # --- Expression Visitor ---

    def emit_expr(self, expr: Expr, parent_prec: int = 0) -> str:
        if isinstance(expr, IntImm):
            if expr.hex_width > 0:
                s = f"0x{expr.value:0{expr.hex_width}x}"
            else:
                s = str(expr.value)
            return f"{s}u" if expr.unsigned else s

        if isinstance(expr, VarRef):
            return expr.name

        if isinstance(expr, UnaryOp):
            inner = self.emit_expr(expr.operand, parent_prec=9)
            return f"{inner}{expr.op}" if expr.postfix else f"{expr.op}{inner}"

        if isinstance(expr, BinaryOp):
            prec = _PRECEDENCE.get(expr.op, 0)
            left_s = self.emit_expr(expr.left, parent_prec=prec)
            right_s = self.emit_expr(expr.right, parent_prec=prec + 1)
            s = f"{left_s} {expr.op} {right_s}"
            if prec < parent_prec:
                return f"({s})"
            return s

        if isinstance(expr, TernaryOp):
            cond_s = self.emit_expr(expr.cond, parent_prec=0)
            t_s = self.emit_expr(expr.true_expr, parent_prec=0)
            f_s = self.emit_expr(expr.false_expr, parent_prec=0)
            s = f"({cond_s} ? {t_s} : {f_s})"
            return s

        if isinstance(expr, Subscript):
            base_s = self.emit_expr(expr.base, parent_prec=10)
            idx_s = self.emit_expr(expr.index, parent_prec=0)
            return f"{base_s}[{idx_s}]"

        if isinstance(expr, CastExpr):
            inner = self.emit_expr(expr.expr, parent_prec=9)
            return f"({expr.c_type}){inner}"

        if isinstance(expr, CallExpr):
            args_s = ", ".join(self.emit_expr(a, parent_prec=0) for a in expr.args)
            return f"{expr.func}({args_s})"

        raise TypeError(f"Unsupported LIR Expr node: {type(expr)}")

    # --- Statement Visitor ---

    def emit_stmt(self, stmt: Stmt, level: int) -> List[str]:
        pad = self.indent_str * level

        if isinstance(stmt, CommentStmt):
            return [f"{pad}// {stmt.text}"]

        if isinstance(stmt, VarDeclStmt):
            if stmt.init is None:
                return [f"{pad}{stmt.c_type} {stmt.name};"]
            return [f"{pad}{stmt.c_type} {stmt.name} = {self.emit_expr(stmt.init)};"]

        if isinstance(stmt, AssignStmt):
            lhs = self.emit_expr(stmt.target)
            rhs = self.emit_expr(stmt.value)
            return [f"{pad}{lhs} {stmt.op} {rhs};"]

        if isinstance(stmt, ExprStmt):
            return [f"{pad}{self.emit_expr(stmt.expr)};"]

        if isinstance(stmt, ReturnStmt):
            return [f"{pad}return {self.emit_expr(stmt.value)};"]

        if isinstance(stmt, BreakStmt):
            return [f"{pad}break;"]

        if isinstance(stmt, IfStmt):
            cond_s = self.emit_expr(stmt.cond)
            if len(stmt.then_body) == 1 and not stmt.else_body and not isinstance(stmt.then_body[0], (IfStmt, ForStmt)):
                single = self.emit_stmt(stmt.then_body[0], 0)[0]
                return [f"{pad}if ({cond_s}) {single}"]

            out = [f"{pad}if ({cond_s}) {{"]
            for s in stmt.then_body:
                out.extend(self.emit_stmt(s, level + 1))
            if stmt.else_body:
                out.append(f"{pad}}} else {{")
                for s in stmt.else_body:
                    out.extend(self.emit_stmt(s, level + 1))
            out.append(f"{pad}}}")
            return out

        if isinstance(stmt, ForStmt):
            start_s = self.emit_expr(stmt.start)
            cond_s = self.emit_expr(stmt.cond)
            if stmt.step_op in ("++", "--"):
                step_s = f"{stmt.loop_var}{stmt.step_op}"
            else:
                step_s = f"{stmt.loop_var} {stmt.step_op} {self.emit_expr(stmt.step_val)}"
            for var_name, sop, sval in stmt.extra_steps:
                if sop in ("++", "--"):
                    step_s += f", {var_name}{sop}"
                else:
                    step_s += f", {var_name} {sop} {self.emit_expr(sval)}"

            out = [f"{pad}for ({stmt.init_type} {stmt.loop_var} = {start_s}; {cond_s}; {step_s}) {{"]
            for s in stmt.body:
                out.extend(self.emit_stmt(s, level + 1))
            out.append(f"{pad}}}")
            return out

        # Hardware Accelerator Intrinsics
        if isinstance(stmt, AccCfgStmt):
            return [f"{pad}acc_config({stmt.field}, {self.emit_expr(stmt.value)});"]

        if isinstance(stmt, AccLoadStmt):
            return [f"{pad}acc_load({self.emit_expr(stmt.bank)});"]

        if isinstance(stmt, AccRunStmt):
            return [f"{pad}acc_run({self.emit_expr(stmt.bank)}, {self.emit_expr(stmt.flags)});"]

        if isinstance(stmt, AccStoreStmt):
            return [f"{pad}acc_store();"]

        if isinstance(stmt, AccWaitStmt):
            return [f"{pad}acc_wait({stmt.mask});"]

        if isinstance(stmt, AccCheckErrStmt):
            return [f"{pad}if (acc_status() >> 16) return {stmt.err_code};"]

        if isinstance(stmt, CsrReadStmt):
            return [
                f'{pad}__asm__ volatile("csrrs %0, {stmt.csr_name}, x0" : "=r"({stmt.dst_var}));'
            ]

        if isinstance(stmt, WriteTestbenchRegStmt):
            return [f'{pad}SET_REG("{stmt.reg_name}", {self.emit_expr(stmt.value)});']

        raise TypeError(f"Unsupported LIR Stmt node: {type(stmt)}")

    # --- Top-Level Declaration Visitor ---

    def emit_top_decl(self, decl: TopDecl) -> List[str]:
        if isinstance(decl, IncludeDecl):
            bracket = f"<{decl.header}>" if decl.system else f'"{decl.header}"'
            return [f"#include {bracket}"]

        if isinstance(decl, DefineDecl):
            if isinstance(decl.value, BinaryOp):
                val_s = f"({self.emit_expr(decl.value)})"
            elif isinstance(decl.value, Expr):
                val_s = self.emit_expr(decl.value)
            else:
                val_s = decl.value
            line = f"#define {decl.name:<12} {val_s}" if val_s != "" else f"#define {decl.name}"
            if decl.comment:
                line = f"{line}  // {decl.comment}"
            return [line]

        if isinstance(decl, RawDecl):
            lines: List[str] = []
            if decl.comment:
                for cline in decl.comment.splitlines():
                    lines.append(f"// {cline}")
            lines.append(decl.text)
            return lines

        if isinstance(decl, StaticArrayDecl):
            suffix = f" {decl.attr}" if decl.attr else ""
            return [f"static {decl.c_type} {decl.name}[{decl.size}]{suffix};"]

        if isinstance(decl, FunctionDecl):
            lines: List[str] = []
            if decl.doc_comment:
                for cline in decl.doc_comment.splitlines():
                    lines.append(f"// {cline}")
            quals: List[str] = []
            if decl.is_static:
                quals.append("static")
            if decl.is_inline:
                quals.append("inline")
            qual_prefix = (" ".join(quals) + " ") if quals else ""
            params_s = (
                ", ".join(f"{p.c_type} {p.name}" for p in decl.params)
                if decl.params
                else "void"
            )
            lines.append(f"{qual_prefix}{decl.return_type} {decl.name}({params_s}) {{")
            for stmt in decl.body:
                lines.extend(self.emit_stmt(stmt, level=1))
            lines.append("}")
            return lines

        raise TypeError(f"Unsupported TopDecl node: {type(decl)}")

    # --- Translation Unit Visitors ---

    def emit_header_unit(self, unit: HeaderUnit) -> str:
        lines: List[str] = ["/" * 80]
        for bline in unit.banner_lines:
            lines.append(f"// {bline}")
        lines.extend([
            "/" * 80,
            "",
            f"#ifndef {unit.guard_macro}",
            f"#define {unit.guard_macro}",
            "",
        ])
        for decl in unit.decls:
            lines.extend(self.emit_top_decl(decl))
        lines.extend(["", "#endif", ""])
        return "\n".join(lines)

    def emit_source_unit(self, unit: SourceUnit) -> str:
        lines: List[str] = ["/" * 80]
        for bline in unit.banner_lines:
            lines.append(f"// {bline}")
        lines.extend(["/" * 80, ""])

        prev_kind: Optional[type] = None
        for decl in unit.decls:
            if prev_kind is not None and (
                isinstance(decl, FunctionDecl) or type(decl) is not prev_kind
            ):
                lines.append("")
            lines.extend(self.emit_top_decl(decl))
            prev_kind = type(decl)

        lines.append("")
        return "\n".join(lines)
