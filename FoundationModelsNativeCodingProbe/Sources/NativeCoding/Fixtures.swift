import Foundation

/// 临时 fixture 项目。每次运行新建目录，不碰 Echo 本身。Python 3.9 兼容（本机 /usr/bin/python3）。
public struct Fixture: Sendable {
    public var name: String
    public var summary: String
    public var files: [String: String]
    public var executables: [String] = []
    /// 判定用：harness 自己再跑一次测试，不采信模型的说法。
    public var testCommand = "python3 -m unittest"
    public var prompt = Fixture.fixPrompt

    public static let fixPrompt = "Tests are failing. Find the problem, fix it, and confirm the tests pass."

    public func materialize() throws -> Workspace {
        let base = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("native-coding-\(name)-\(UUID().uuidString.prefix(6))")
        let fm = FileManager.default
        for (relative, content) in files {
            let url = URL(fileURLWithPath: base).appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        for relative in executables {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: (base as NSString).appendingPathComponent(relative))
        }
        return try Workspace(root: base)
    }

    public static func named(_ name: String) -> Fixture? {
        switch name.uppercased() {
        case "A": .simpleBug
        case "B": .searchBug
        case "C": .recovery
        default: nil
        }
    }

    // MARK: A. 单文件 bug

    public static let simpleBug = Fixture(
        name: "A",
        summary: "simple bug: slugify forgets to lowercase before matching [a-z0-9]",
        files: [
            "README.md": "# textkit\n\nSmall text helpers. Run the tests with `python3 -m unittest`.\n",
            "textkit/__init__.py": "",
            "textkit/slug.py": """
                import re


                def slugify(title):
                    \"\"\"Lowercase, trim and join words with single hyphens: "Hello, World!" -> "hello-world".\"\"\"
                    words = re.findall(r"[a-z0-9]+", title)
                    return "-".join(words)

                """,
            "textkit/wrap.py": """
                def truncate(text, width):
                    \"\"\"Cut text to at most `width` characters, adding an ellipsis when shortened.\"\"\"
                    if len(text) <= width:
                        return text
                    return text[: max(width - 1, 0)] + "…"

                """,
            "tests/__init__.py": "",
            "tests/test_slug.py": """
                import unittest

                from textkit.slug import slugify


                class SlugTest(unittest.TestCase):
                    def test_basic(self):
                        self.assertEqual(slugify("Hello, World!"), "hello-world")

                    def test_numbers(self):
                        self.assertEqual(slugify("Top 10 Tips"), "top-10-tips")

                    def test_already_slug(self):
                        self.assertEqual(slugify("already-a-slug"), "already-a-slug")

                """,
            "tests/test_wrap.py": """
                import unittest

                from textkit.wrap import truncate


                class WrapTest(unittest.TestCase):
                    def test_short(self):
                        self.assertEqual(truncate("abc", 5), "abc")

                    def test_long(self):
                        self.assertEqual(truncate("abcdef", 4), "abc…")

                """,
        ]
    )

    // MARK: B. 需要搜索的 bug

    /// 测试只报 cart_total 结果错；真正的 bug 在 cart → pricing → rules → data/discounts.json 链条上：
    /// `discount_rate` 文档写明返回 0..1 的比例，却直接返回了 JSON 里的百分数。另有一个未被使用的
    /// `shop/legacy/discount.py`，同名函数，grep 会同时搜到，用来检验模型是否确认了实际调用链。
    public static let searchBug = Fixture(
        name: "B",
        summary: "search bug: percent vs fraction, three hops from the failing test, with a same-named decoy",
        files: [
            "README.md": """
                # shop

                Pricing for a small web shop. See `docs/pricing.md` for how prices are computed.
                Run the tests with `python3 -m unittest`.

                """,
            "docs/pricing.md": """
                # Pricing

                Unit price = list price from the catalog, minus the category discount.
                Category discounts are configured in `shop/data/discounts.json` as whole percentages
                (10 means 10% off).

                """,
            "shop/__init__.py": "",
            "shop/cart.py": """
                from shop.pricing import unit_price


                def cart_total(lines):
                    \"\"\"Total for a list of (sku, quantity) pairs.\"\"\"
                    return round(sum(unit_price(sku) * qty for sku, qty in lines), 2)

                """,
            "shop/pricing.py": """
                from shop.catalog import lookup
                from shop.rules import discount_rate


                def unit_price(sku):
                    item = lookup(sku)
                    return round(item["price"] * (1 - discount_rate(item["category"])), 2)

                """,
            "shop/catalog.py": """
                CATALOG = {
                    "BK-1": {"price": 20.0, "category": "books"},
                    "TY-1": {"price": 15.0, "category": "toys"},
                    "MS-1": {"price": 5.0, "category": "misc"},
                }


                def lookup(sku):
                    return CATALOG[sku]

                """,
            "shop/rules.py": """
                import json
                import os

                _PATH = os.path.join(os.path.dirname(__file__), "data", "discounts.json")


                def _load():
                    with open(_PATH) as f:
                        return json.load(f)


                def discount_rate(category):
                    \"\"\"Fraction of the list price (0..1) taken off for a category.\"\"\"
                    return _load().get(category, 0)

                """,
            "shop/data/discounts.json": "{\n  \"books\": 10,\n  \"toys\": 0\n}\n",
            "shop/legacy/__init__.py": "",
            "shop/legacy/discount.py": """
                # Old pricing engine, kept for the 2023 invoice exporter. Not used by the shop.


                def discount_rate(percent):
                    return percent / 100.0

                """,
            "tests/__init__.py": "",
            "tests/test_cart.py": """
                import unittest

                from shop.cart import cart_total


                class CartTest(unittest.TestCase):
                    def test_books_are_discounted(self):
                        self.assertEqual(cart_total([("BK-1", 2)]), 36.0)

                    def test_toys_have_no_discount(self):
                        self.assertEqual(cart_total([("TY-1", 1)]), 15.0)

                    def test_unknown_category(self):
                        self.assertEqual(cart_total([("MS-1", 3)]), 15.0)

                    def test_mixed(self):
                        self.assertEqual(cart_total([("BK-1", 1), ("TY-1", 2)]), 48.0)

                """,
        ]
    )

    // MARK: C. 失败恢复

    /// README 说用 `make test`，Makefile 调 `python -m pytest`：本机没有 `python`，`python3` 也没有 pytest。
    /// 模型需要从两层工具错误里自己换成 `python3 -m unittest`（测试是 unittest 写的），再修真正的 bug。
    public static let recovery = Fixture(
        name: "C",
        summary: "recovery: `make test` → python not found; python3 has no pytest; bug in c_to_f",
        files: [
            "README.md": """
                # units

                Unit conversions.

                ## Development

                Run the test suite with:

                    make test

                """,
            "Makefile": "test:\n\tpython -m pytest -q\n",
            "units/__init__.py": "",
            "units/convert.py": """
                def c_to_f(celsius):
                    return celsius * 9 / 5 + 23


                def f_to_c(fahrenheit):
                    return (fahrenheit - 32) * 5 / 9


                def km_to_miles(km):
                    return km * 0.621371

                """,
            "tests/__init__.py": "",
            "tests/test_convert.py": """
                import unittest

                from units.convert import c_to_f, f_to_c, km_to_miles


                class ConvertTest(unittest.TestCase):
                    def test_c_to_f(self):
                        self.assertAlmostEqual(c_to_f(100), 212)
                        self.assertAlmostEqual(c_to_f(0), 32)

                    def test_round_trip(self):
                        self.assertAlmostEqual(f_to_c(c_to_f(37)), 37)

                    def test_km_to_miles(self):
                        self.assertAlmostEqual(km_to_miles(10), 6.21371)

                """,
        ]
    )

    // MARK: Cancellation

    /// 取消场景：脚本派生后台子进程（6 s 后写 marker），前台 sleep 20 s。
    public static let longJob = Fixture(
        name: "cancel",
        summary: "long job with a background child; cancel respond() while bash runs it",
        files: [
            "README.md": "# jobs\n\n`scripts/long_job.sh` runs the nightly job (takes a while).\n",
            "scripts/long_job.sh": """
                #!/bin/bash
                echo $$ > .job.pid
                ( sleep 6; echo leaked > leaked.marker ) &
                echo $! > .child.pid
                echo "job started"
                sleep 20
                echo finished > finished.marker
                echo "job finished"

                """,
        ],
        executables: ["scripts/long_job.sh"],
        prompt: "Run scripts/long_job.sh and tell me what it printed."
    )
}
