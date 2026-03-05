#!/usr/bin/env python3
"""
Unit tests for the PageRank algorithm — CS 528 HW2

All tests use small, hand-crafted graphs whose expected PageRank values
can be derived analytically.  They are completely independent of the
randomly generated 20K-file dataset.

Run:  python -m pytest test_pagerank.py -v
  or: python test_pagerank.py
"""

import unittest
from pagerank_analysis import pagerank, parse_outgoing_links


class TestParseLinks(unittest.TestCase):

    def test_typical_html(self):
        html = ('<!DOCTYPE html>\n<html><body>\n'
                '<a HREF="42.html"> This is a link </a>\n<p>\n'
                '<a HREF="100.html"> This is a link </a>\n'
                '</body></html>')
        self.assertEqual(parse_outgoing_links(html), ['42.html', '100.html'])

    def test_no_links(self):
        html = '<!DOCTYPE html>\n<html><body>Hello</body></html>'
        self.assertEqual(parse_outgoing_links(html), [])

    def test_duplicate_links(self):
        html = ('<a HREF="5.html"> link </a>\n'
                '<a HREF="5.html"> link </a>\n'
                '<a HREF="3.html"> link </a>')
        self.assertEqual(parse_outgoing_links(html), ['5.html', '5.html', '3.html'])


class TestPageRank(unittest.TestCase):
    """
    Every test constructs an `outgoing` dict (same format the main
    program builds from the HTML files) and feeds it to pagerank().
    """

    # -- Symmetric cycle: A -> B -> C -> A ----------------------------------
    def test_cycle_equal_pr(self):
        """In a symmetric cycle every page must have equal PageRank."""
        outgoing = {
            'a.html': ['b.html'],
            'b.html': ['c.html'],
            'c.html': ['a.html'],
        }
        pr, _ = pagerank(outgoing, verbose=False)
        for page in outgoing:
            self.assertAlmostEqual(pr[page], 1 / 3, places=4)

    # -- Star: many pages point to one hub -----------------------------------
    def test_star_hub_has_highest_pr(self):
        """The hub page (most incoming links) must have the highest PR."""
        outgoing = {
            '0.html': ['1.html'],
            '1.html': ['0.html'],
            '2.html': ['0.html'],
            '3.html': ['0.html'],
        }
        pr, _ = pagerank(outgoing, verbose=False)
        self.assertEqual(max(pr, key=pr.get), '0.html')
        # Pages 2 and 3 are symmetric — same PR
        self.assertAlmostEqual(pr['2.html'], pr['3.html'], places=6)

    # -- Dangling node: exact analytical values ------------------------------
    def test_dangling_node_exact_values(self):
        """
        Graph:
            0 -> 1, 0 -> 2
            1 -> 0
            2 -> (nothing)          ← dangling node

        Analytical steady-state (d = 0.85, n = 3):
            PR(0) = 74/511  ≈ 0.14482
            PR(1) = 57/511  ≈ 0.11155
            PR(2) = 57/511  ≈ 0.11155

        Because node 2 is dangling the total PR sum < 1 and actually
        changes across iterations, so the sum-based convergence
        criterion is meaningful here.  We use a tight threshold to
        get close to the analytical values.
        """
        outgoing = {
            '0.html': ['1.html', '2.html'],
            '1.html': ['0.html'],
            '2.html': [],
        }
        pr, iters = pagerank(outgoing, threshold=1e-10, verbose=False)

        self.assertAlmostEqual(pr['0.html'], 74 / 511, places=4)
        self.assertAlmostEqual(pr['1.html'], 57 / 511, places=4)
        self.assertAlmostEqual(pr['2.html'], 57 / 511, places=4)
        # Must have taken more than 1 iteration
        self.assertGreater(iters, 1)

    # -- No incoming links → minimum PR = (1-d)/n ---------------------------
    def test_no_incoming_gets_base_pr(self):
        """A page nobody links to receives only the base PR = 0.15/n."""
        outgoing = {
            '0.html': ['1.html'],
            '1.html': ['0.html'],
            '2.html': ['0.html'],   # outgoing but NO incoming
        }
        pr, _ = pagerank(outgoing, verbose=False)
        self.assertAlmostEqual(pr['2.html'], 0.15 / 3, places=4)

    # -- Ordering: more incoming → higher PR ---------------------------------
    def test_ordering_by_incoming(self):
        """
        Graph:
            A -> B, A -> C
            B -> C
            C -> A

        C has 2 incoming (from A and B), A has 1 (from C), B has 1 (from A).
        Expected order: C > A > B.
        """
        outgoing = {
            'a.html': ['b.html', 'c.html'],
            'b.html': ['c.html'],
            'c.html': ['a.html'],
        }
        pr, _ = pagerank(outgoing, verbose=False)
        self.assertGreater(pr['c.html'], pr['a.html'])
        self.assertGreater(pr['a.html'], pr['b.html'])

    # -- Single page (edge case) --------------------------------------------
    def test_single_page_no_links(self):
        """A single page with no links should get PR = (1-d)/n = 0.15."""
        outgoing = {'0.html': []}
        pr, _ = pagerank(outgoing, verbose=False)
        self.assertAlmostEqual(pr['0.html'], 0.15, places=4)

    def test_single_page_self_link(self):
        """A single page linking to itself should get PR = 1.0."""
        outgoing = {'0.html': ['0.html']}
        pr, _ = pagerank(outgoing, verbose=False)
        self.assertAlmostEqual(pr['0.html'], 1.0, places=4)

    # -- Convergence sanity --------------------------------------------------
    def test_convergence_terminates(self):
        """Algorithm must terminate and produce positive ranks."""
        outgoing = {
            '0.html': ['1.html', '2.html'],
            '1.html': ['0.html'],
            '2.html': ['0.html', '1.html'],
        }
        pr, iters = pagerank(outgoing, verbose=False)
        self.assertGreater(iters, 0)
        for v in pr.values():
            self.assertGreater(v, 0)

    # -- Sum of PageRanks = 1.0 (no dangling nodes) -------------------------
    def test_sum_of_pageranks_equals_one(self):
        """
        When there are no dangling nodes (every page has at least one
        outgoing link), the sum of all PageRank values must equal 1.0.
        This is the primary correctness check recommended by the TAs.
        """
        # Small fully-connected graph — no dangling nodes
        outgoing = {
            '0.html': ['1.html', '2.html', '3.html'],
            '1.html': ['0.html', '2.html'],
            '2.html': ['3.html'],
            '3.html': ['0.html', '1.html'],
        }
        pr, _ = pagerank(outgoing, threshold=1e-10, verbose=False)
        self.assertAlmostEqual(sum(pr.values()), 1.0, places=4)

    def test_sum_of_pageranks_larger_graph(self):
        """
        Same sum-to-one check on a larger graph (10 nodes, no dangling).
        """
        outgoing = {
            '0.html': ['1.html', '5.html'],
            '1.html': ['2.html', '3.html'],
            '2.html': ['0.html', '4.html'],
            '3.html': ['4.html', '7.html'],
            '4.html': ['5.html'],
            '5.html': ['6.html', '9.html'],
            '6.html': ['7.html', '0.html'],
            '7.html': ['8.html'],
            '8.html': ['9.html', '3.html'],
            '9.html': ['0.html', '1.html'],
        }
        pr, _ = pagerank(outgoing, threshold=1e-10, verbose=False)
        self.assertAlmostEqual(sum(pr.values()), 1.0, places=4)


if __name__ == '__main__':
    unittest.main()
