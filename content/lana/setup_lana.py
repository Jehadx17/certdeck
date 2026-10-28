# Run on the server: docker exec -i certdeck-certdeck-api-1 python manage.py shell < setup_lana.py
# Creates student "lana" (once), copies jood's English word course (progress-free), adds the CS163 subject with its
# 12 lectures as chapters and CS112 with its 7 chapter parts, MATH106 with its 20 sections, GS111 with its 13 topics, and turns on "Rotate card versions". Re-runs only add what is missing.
from core.models import Account, Doc, now_ms, save_docs

PROGRESS = {"fsrs", "priority", "sure_streak", "misconception", "id"}
CS163 = [
    ("L01", "Lecture 1: Introduction and Preliminaries"), ("L02", "Lecture 2: Propositional Logic"),
    ("L03", "Lecture 3: Implication and Bi-conditional"), ("L04", "Lecture 4: Logical Equivalences"),
    ("L05", "Lecture 5: Predicates and Quantifiers"), ("L06", "Lecture 6: Rules of Inference and Proof Techniques"),
    ("L07", "Lecture 7: Sets · midterm"), ("L08", "Lecture 8: Relations and Functions · midterm"),
    ("L09", "Lecture 9: Induction and Recurrence"), ("L10", "Lecture 10: Counting · midterm"),
    ("L11", "Lecture 11: Introduction to Probability"), ("L12", "Lecture 12: Graphs and Trees · midterm"),
]
CS112 = [
    ("C09a", "Chapter 9: Objects and Classes (1)"), ("C09b", "Chapter 9: Objects and Classes (2)"),
    ("C10a", "Chapter 10: Thinking in Objects (1)"), ("C10b", "Chapter 10: Thinking in Objects (2)"),
    ("C11a", "Chapter 11: Inheritance and Polymorphism (1)"), ("C11b", "Chapter 11: Inheritance and Polymorphism (2)"),
    ("C13", "Chapter 13: Abstract Classes and Interfaces"),
]
MID = {"6.1", "7.1", "7.2", "7.3", "7.4", "7.5", "7.8"}
MATH106 = [(s, f"{s} {t}" + (" · midterm" if s in MID else "")) for s, t in [
    ("5.2", "The Indefinite Integral"), ("5.3", "Integration by Substitution"), ("5.5", "The Definite Integral"),
    ("5.6", "The Fundamental Theorem of Calculus"), ("5.9", "Evaluating Definite Integrals by Substitution"),
    ("6.9", "Hyperbolic Functions and Inverse Hyperbolic Functions"), ("7.1", "An Overview of Integration Methods"),
    ("7.2", "Integration by Parts"), ("7.3", "Integrating Trigonometric Functions"), ("7.4", "Trigonometric Substitutions"),
    ("7.5", "Integrating Rational Functions by Partial Fractions"), ("7.8", "Improper Integrals"),
    ("6.1", "Area Between Two Curves"), ("6.2", "Volumes by Slicing; Disks and Washers"), ("9.1", "Sequences"),
    ("9.3", "Infinite Series"), ("9.4", "Convergence Tests"), ("9.5", "The Comparison, Ratio, and Root Tests"),
    ("9.7", "Maclaurin and Taylor Polynomials"), ("9.8", "Maclaurin and Taylor Series; Power Series")]]
GS111 = [(f"T{n:02d}", f"الموضوع {o}: {t}") for n, (o, t) in enumerate([
    ("الأول", "مدخل إلى مهارات اللغة"), ("الثاني", "مهارات التحدث وآداب الحوار والنقاش"), ("الثالث", "القراءة الجهرية"),
    ("الرابع", "مهارات القراءة الجهرية وتقويمها"), ("الخامس", "تطبيقات على القراءة الجهرية"),
    ("السادس", "القراءة الصامتة"), ("السابع", "تطبيق مهارة القراءة الصامتة"),
    ("الثامن", "القراءة السريعة والقراءة الممتدة"), ("التاسع", "تطبيق على القراءة السريعة"),
    ("العاشر", "تطبيق على القراءة الممتدة"), ("الحادي عشر", "القراءة الجمالية الأدبية"),
    ("الثاني عشر", "القراءة الشمولية والنظام النحوي"), ("الثالث عشر", "التطبيق الختامي")], 1)]

a, made = Account.objects.get_or_create(name="lana", defaults={"role": "student", "cap_usd": 0, "email": "lana@certdeck.app"})
if made:
    a.set_password("1Qw23er45t")
    a.save()
print("account", a.name, a.email, a.role, "created" if made else "exists")

jood = Account.objects.get(email="jood@certdeck.app")
have = set(Doc.objects.filter(user=a).values_list("doc_id", flat=True))
now, docs = now_ms(), []
for d in Doc.objects.filter(user=jood, deleted=False, kind__in=["course", "assessment", "card"]):
    if d.doc_id in have or (d.kind == "card" and d.data.get("course") != "oxford3000"):
        continue
    data = {k: v for k, v in d.data.items() if k not in PROGRESS}
    if d.kind == "card":
        data["new"] = True
    docs.append({"id": d.doc_id, "kind": d.kind, "data": {**data, "created_at": now}, "updated_at": now, "deleted": False})

if "cs163" not in have:
    docs.append({"id": "cs163", "kind": "course", "updated_at": now, "deleted": False,
                 "data": {"name": "Discrete Structures (CS163)", "code": "CS163", "lang": "en", "created_at": now}})
if "cs163-all" not in have:
    docs.append({"id": "cs163-all", "kind": "assessment", "updated_at": now, "deleted": False, "data": {
        "course_id": "cs163", "kind": "quiz", "title": "Discrete Structures", "date": None, "hints": "", "status": "active",
        "source": "import", "created_at": now,
        "scope": [{"material_id": "cs163", "section_id": sid, "title": title} for sid, title in CS163]}})
if "cs112" not in have:
    docs.append({"id": "cs112", "kind": "course", "updated_at": now, "deleted": False,
                 "data": {"name": "Programming 2 (CS112)", "code": "CS112", "lang": "en", "created_at": now}})
if "cs112-all" not in have:
    docs.append({"id": "cs112-all", "kind": "assessment", "updated_at": now, "deleted": False, "data": {
        "course_id": "cs112", "kind": "quiz", "title": "Programming 2", "date": None, "hints": "", "status": "active",
        "source": "import", "created_at": now,
        "scope": [{"material_id": "cs112", "section_id": sid, "title": title} for sid, title in CS112]}})
if "math106" not in have:
    docs.append({"id": "math106", "kind": "course", "updated_at": now, "deleted": False,
                 "data": {"name": "Calculus 2 (MATH106)", "code": "MATH106", "lang": "en", "created_at": now}})
if "math106-all" not in have:
    docs.append({"id": "math106-all", "kind": "assessment", "updated_at": now, "deleted": False, "data": {
        "course_id": "math106", "kind": "quiz", "title": "Calculus 2", "date": None, "hints": "", "status": "active",
        "source": "import", "created_at": now,
        "scope": [{"material_id": "math106", "section_id": sid, "title": title} for sid, title in MATH106]}})
if "gs111" not in have:
    docs.append({"id": "gs111", "kind": "course", "updated_at": now, "deleted": False,
                 "data": {"name": "مهارات اللغة العربية (GS111)", "code": "GS111", "lang": "ar", "created_at": now}})
if "gs111-all" not in have:
    docs.append({"id": "gs111-all", "kind": "assessment", "updated_at": now, "deleted": False, "data": {
        "course_id": "gs111", "kind": "quiz", "title": "مهارات اللغة العربية", "date": None, "hints": "", "status": "active",
        "source": "import", "created_at": now,
        "scope": [{"material_id": "gs111", "section_id": sid, "title": title} for sid, title in GS111]}})
if "settings" not in have:
    docs.append({"id": "settings", "kind": "settings", "updated_at": now, "deleted": False,
                 "data": {"id": "settings", "rotate_versions": True}})

print("saved", save_docs(a, docs), "docs")
print("cards", Doc.objects.filter(user=a, kind="card", deleted=False).count())
