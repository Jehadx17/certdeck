"""Checks the AI's math before a problem card is saved: a wrong answer key costs a student marks.

The model states how to check its final answer as SymPy expressions; we evaluate them here instead of trusting it.
Expressions come from model output that read untrusted course material, so they are filtered to a small grammar
(numbers, single-letter variables, known function names, operators) and evaluated in a child process with CPU,
memory and time limits.

    check = {"kind": "numeric", "expr": "integrate(x**2, (x, 0, 3))", "value": "9", "tolerance": 1e-6}
    check = {"kind": "equivalent", "expr": "(x+1)**2", "value": "x**2 + 2*x + 1"}
    check = {"kind": "derivative", "expr": "(x**2+1)**51/102", "value": "x*(x**2+1)**50", "var": "x"}  # d/dx expr == value
    check = {"kind": "solutions", "expr": "x**2 - 5*x + 6", "value": "2, 3", "var": "x"}  # roots of expr == 0
"""
import json
import re
import resource
import subprocess
import sys

FUNCS = {
    "sin", "cos", "tan", "cot", "sec", "csc", "asin", "acos", "atan", "acot", "sinh", "cosh", "tanh", "asinh", "acosh",
    "atanh", "exp", "log", "ln", "sqrt", "cbrt", "root", "Abs", "factorial", "binomial", "gamma", "floor", "ceiling",
    "integrate", "diff", "limit", "Sum", "summation", "Product", "Rational", "pi", "E", "I", "oo", "Integer", "Float",
    "simplify", "expand", "factor", "Matrix", "det", "Min", "Max", "gcd", "lcm", "Mod", "nCr", "nPr",
}
TOKEN = re.compile(r"\s*(?:(\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)|([A-Za-z_][A-Za-z_0-9]*)|(\*\*|[-+*/^(),\[\]=]))")
KINDS = ("numeric", "equivalent", "derivative", "solutions")


def safe(expr):
    """True if expr only uses numbers, operators, single-letter variables and whitelisted function names."""
    if not isinstance(expr, str) or not expr.strip() or len(expr) > 400:
        return False
    pos = 0
    while pos < len(expr):
        m = TOKEN.match(expr, pos)
        if not m or m.end() == pos:
            return expr[pos:].strip() == ""
        name = m.group(2)
        if name and not (name in FUNCS or re.fullmatch(r"[A-Za-z](_?\d)?", name)):
            return False
        pos = m.end()
    return True


def check(spec, timeout=10):
    """True = verified, False = the answer is wrong or unverifiable (drop the problem)."""
    if not isinstance(spec, dict) or spec.get("kind") not in KINDS:
        return False
    if not (safe(spec.get("expr")) and safe(str(spec.get("value", "")))):
        return False
    if spec.get("var") is not None and not re.fullmatch(r"[A-Za-z]", str(spec["var"])):
        return False
    try:
        out = subprocess.run([sys.executable, "-I", __file__], input=json.dumps(spec), capture_output=True, text=True,
                             timeout=timeout, preexec_fn=_limits)
    except subprocess.TimeoutExpired:
        return False
    return out.stdout.strip() == "ok"


def _limits():
    resource.setrlimit(resource.RLIMIT_CPU, (8, 8))
    resource.setrlimit(resource.RLIMIT_AS, (1 << 30, 1 << 30))


def _run(spec):  # in the child process
    import sympy as sp
    from sympy.parsing.sympy_parser import (convert_xor, implicit_multiplication_application, parse_expr,
                                            standard_transformations)

    names = {n: getattr(sp, n) for n in FUNCS if hasattr(sp, n)}
    names.update(ln=sp.log, cbrt=sp.cbrt, summation=sp.summation, nCr=sp.binomial,
                 nPr=lambda n, k: sp.factorial(n) / sp.factorial(n - k))
    tf = standard_transformations + (implicit_multiplication_application, convert_xor)
    sympy_names = {k: v for k, v in vars(sp).items() if not k.startswith("_")}

    def p(s):
        return parse_expr(str(s), local_dict=dict(names), global_dict={**sympy_names, "__builtins__": {}},
                          transformations=tf)

    kind = spec["kind"]
    expr = p(spec["expr"])
    if kind == "numeric":
        a, b = complex(sp.N(expr.doit() if hasattr(expr, "doit") else expr)), complex(sp.N(p(spec["value"])))
        tol = float(spec.get("tolerance") or 1e-6)
        return abs(a - b) <= max(tol, tol * abs(b))
    var = sp.Symbol(spec.get("var") or "x")
    value = p(spec["value"])
    if kind == "equivalent":
        return sp.simplify(expr - value) == 0
    if kind == "derivative":
        return sp.simplify(sp.diff(expr, var) - value) == 0
    if kind == "solutions":
        want = {sp.nsimplify(v) for v in (value if isinstance(value, tuple) else (value,))}
        return set(sp.solve(sp.Eq(expr, 0), var)) == want
    return False


if __name__ == "__main__":
    try:
        print("ok" if _run(json.loads(sys.stdin.read())) else "wrong")
    except Exception as e:  # noqa: BLE001 - any failure means "not verified"
        print(f"error {type(e).__name__}")
