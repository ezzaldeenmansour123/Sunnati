#!/usr/bin/env python3
"""Tests for tools/isnad_parser.py — SUNNATI Phase 5.

Run from the repo root or the tools dir:
    python3 -m unittest tools.test_isnad_parser -v
    python3 tools/test_isnad_parser.py

The sample texts are verbatim isnad prefixes (with tashkeel as stored)
from ~/workspace/phase5-work/work.db: Bukhari 1 and 7, Muslim 3 and 93,
Ahmad 1, 2, 3, 4, 5, plus Bukhari 2 and 4. Only the isnad and the first
matn words are embedded — enough for the parser to find the boundary.

Nothing here invents a narrator identity: every assertion about linking
is that the parser does NOT link (narrator_id is None, match_status is
'unlinked' / 'needs_review').
"""
from __future__ import annotations

import sys
import json
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from isnad_parser import (  # noqa: E402
    CONFIDENCE_AR, normalize_text, parse_isnad, resolve_identity,
)

BUKHARI_1 = (
    "حَدَّثَنَا الْحُمَيْدِيُّ عَبْدُ اللَّهِ بْنُ الزُّبَيْرِ ، قَالَ : "
    "حَدَّثَنَا سُفْيَانُ ، قَالَ : حَدَّثَنَا يَحْيَى بْنُ سَعِيدٍ "
    "الْأَنْصَارِيُّ ، قَالَ : أَخْبَرَنِي مُحَمَّدُ بْنُ إِبْرَاهِيمَ "
    "التَّيْمِيُّ ، أَنَّهُ سَمِعَ عَلْقَمَةَ بْنَ وَقَّاصٍ اللَّيْثِيَّ ، "
    "يَقُولُ : سَمِعْتُ عُمَرَ بْنَ الْخَطَّابِ رَضِيَ اللَّهُ عَنْهُ عَلَى "
    "الْمِنْبَرِ، قَالَ : سَمِعْتُ رَسُولَ اللَّهِ صَلَّى اللَّهُ عَلَيْهِ "
    "وَسَلَّمَ يَقُولُ : إِنَّمَا الْأَعْمَالُ بِالنِّيَّاتِ"
)

BUKHARI_7 = (
    "حَدَّثَنَا أَبُو الْيَمَانِ الْحَكَمُ بْنُ نَافِعٍ، قَالَ أَخْبَرَنَا "
    "شُعَيْبٌ، عَنِ الزُّهْرِيِّ، قَالَ أَخْبَرَنِي عُبَيْدُ اللَّهِ بْنُ "
    "عَبْدِ اللَّهِ بْنِ عُتْبَةَ بْنِ مَسْعُودٍ، أَنَّ عَبْدَ اللَّهِ بْنَ "
    "عَبَّاسٍ، أَخْبَرَهُ أَنَّ أَبَا سُفْيَانَ بْنَ حَرْبٍ أَخْبَرَهُ أَنَّ "
    "هِرَقْلَ أَرْسَلَ إِلَيْهِ فِي رَكْبٍ مِنْ قُرَيْشٍ"
)

BUKHARI_2 = (
    "حَدَّثَنَا عَبْدُ اللَّهِ بْنُ يُوسُفَ، قَالَ أَخْبَرَنَا مَالِكٌ، عَنْ "
    "هِشَامِ بْنِ عُرْوَةَ، عَنْ أَبِيهِ، عَنْ عَائِشَةَ أُمِّ "
    "الْمُؤْمِنِينَ ـ رضى الله عنها ـ أَنَّ الْحَارِثَ بْنَ هِشَامٍ ـ رضى "
    "الله عنه ـ سَأَلَ رَسُولَ اللَّهِ صلى الله عليه وسلم فَقَالَ يَا "
    "رَسُولَ اللَّهِ كَيْفَ يَأْتِيكَ الْوَحْىُ"
)

BUKHARI_4 = (
    "قَالَ ابْنُ شِهَابٍ وَأَخْبَرَنِي أَبُو سَلَمَةَ بْنُ عَبْدِ "
    "الرَّحْمَنِ، أَنَّ جَابِرَ بْنَ عَبْدِ اللَّهِ الأَنْصَارِيَّ، قَالَ ـ "
    "وَهُوَ يُحَدِّثُ عَنْ فَتْرَةِ الْوَحْىِ، فَقَالَ ـ فِي حَدِيثِهِ "
    "بَيْنَا أَنَا أَمْشِي، إِذْ سَمِعْتُ صَوْتًا، مِنَ السَّمَاءِ"
)

MUSLIM_3 = (
    "وَحَدَّثَنِي زُهَيْرُ بْنُ حَرْبٍ، حَدَّثَنَا إِسْمَاعِيلُ، - يَعْنِي "
    "ابْنَ عُلَيَّةَ - عَنْ عَبْدِ الْعَزِيزِ بْنِ صُهَيْبٍ، عَنْ أَنَسِ "
    "بْنِ مَالِكٍ، أَنَّهُ قَالَ إِنَّهُ لَيَمْنَعُنِي أَنْ أُحَدِّثَكُمْ "
    "حَدِيثًا كَثِيرًا أَنَّ رَسُولَ اللَّهِ صلى الله عليه وسلم قَالَ"
)

MUSLIM_93 = (
    "حَدَّثَنِي أَبُو خَيْثَمَةَ، زُهَيْرُ بْنُ حَرْبٍ حَدَّثَنَا وَكِيعٌ، "
    "عَنْ كَهْمَسٍ، عَنْ عَبْدِ اللَّهِ بْنِ بُرَيْدَةَ، عَنْ يَحْيَى بْنِ "
    "يَعْمَرَ، ح وَحَدَّثَنَا عُبَيْدُ اللَّهِ بْنُ مُعَاذٍ الْعَنْبَرِيُّ، "
    "- وَهَذَا حَدِيثُهُ - حَدَّثَنَا أَبِي، حَدَّثَنَا كَهْمَسٌ، عَنِ ابْنِ "
    "بُرَيْدَةَ، عَنْ يَحْيَى بْنِ يَعْمَرَ، قَالَ لَمَّا تَكَلَّمَ مَعْبَدٌ"
)

AHMAD_1 = (
    "حدثنا عبد الله بن نمير قال أخبرنا إسماعيل يعني ابن أبي خالد عن قيس "
    "قال قام أبو بكر رضي الله عنه فحمد الله وأثنى عليه ثم قال يا أيها "
    "الناس إنكم تقرءون هذه الآية"
)

AHMAD_2 = (
    "حدثنا وكيع قال حدثنا مسعر وسفيان عن عثمان بن المغيرة الثقفي عن علي "
    "بن ربيعة الوالبي عن أسماء بن الحكم الفزاري عن علي رضي الله عنه قال "
    "كنت إذا سمعت من رسول الله صلى الله عليه وسلم حديثا نفعني الله بما "
    "شاء منه"
)

AHMAD_3 = (
    "حدثنا عمرو بن محمد أبو سعيد يعني العنقزي قال حدثنا إسرائيل عن أبي "
    "إسحاق عن البراء بن عازب قال اشترى أبو بكر من عازب سرجا بثلاثة عشر "
    "درهما"
)

AHMAD_4 = (
    "حدثنا وكيع قال قال إسرائيل قال أبو إسحاق عن زيد بن يثيع عن أبي بكر "
    "أن النبي صلى الله عليه وسلم بعثه ببراءة لأهل مكة"
)

AHMAD_5 = (
    "حدثنا محمد بن جعفر قال حدثنا شعبة عن يزيد بن خمير عن سليم بن عامر "
    "عن أوسط قال خطبنا أبو بكر رضي الله عنه فقال قام رسول الله صلى الله "
    "عليه وسلم مقامي هذا عام الأول"
)


def norms(res):
    return [n.narrator_norm for n in res.narrators]


def by_norm(res, norm):
    for n in res.narrators:
        if n.narrator_norm == norm:
            return n
    return None


class TestBukhariSamples(unittest.TestCase):
    def test_bukhari_1_full_chain(self):
        res = parse_isnad(BUKHARI_1, book="bukhari", hadith_number="1")
        self.assertEqual(
            norms(res),
            ["الحميدي عبد الله بن الزبير", "سفيان",
             "يحيي بن سعيد الانصاري", "محمد بن ابراهيم التيمي",
             "علقمه بن وقاص الليثي", "عمر بن الخطاب"])
        self.assertEqual(res.isnad_status, "complete_with_review")
        self.assertTrue(res.isnad_complete)
        self.assertTrue(res.companion_marked)
        self.assertEqual(res.boundary_reason, "matn_after_qala")
        # Positions are sequential in chain order.
        self.assertEqual([n.position for n in res.narrators],
                         [1, 2, 3, 4, 5, 6])
        # Confidence: multi-word names high, single-word سفيان review.
        self.assertEqual(res.narrators[0].confidence, "high")
        self.assertEqual(res.narrators[1].confidence, "needs_review")
        self.assertEqual(res.narrators[1].match_status, "needs_review")
        self.assertEqual(res.narrators[5].confidence, "high")
        self.assertTrue(res.narrators[5].companion_marked)
        # No narrator is ever linked.
        self.assertTrue(all(n.narrator_id is None for n in res.narrators))
        # Offsets point at the verbatim slice in the original text.
        for n in res.narrators:
            self.assertEqual(
                normalize_text(BUKHARI_1[n.start_char:n.end_char]),
                n.narrator_norm)
            self.assertLess(n.start_char, n.end_char)

    def test_bukhari_7_stops_before_heraclius(self):
        res = parse_isnad(BUKHARI_7, book="bukhari", hadith_number="7")
        self.assertIn("ابو اليمان الحكم بن نافع", norms(res))
        self.assertIn("شعيب", norms(res))
        self.assertIn("الزهري", norms(res))
        self.assertIn("عبيد الله بن عبد الله بن عتبه بن مسعود", norms(res))
        self.assertIn("عبد الله بن عباس", norms(res))
        self.assertIn("ابو سفيان بن حرب", norms(res))
        # هرقل is the matn's subject (أرسل إليه), NOT a narrator.
        self.assertNotIn("هرقل", norms(res))
        self.assertTrue(res.isnad_complete)
        self.assertEqual(res.isnad_status, "complete_with_review")
        # Single-word names are flagged, never linked.
        for single in ("شعيب", "الزهري"):
            n = by_norm(res, single)
            self.assertIsNotNone(n, single)
            self.assertEqual(n.confidence, "needs_review")
            self.assertIsNone(n.narrator_id)

    def test_bukhari_2_companion_and_matn_questioner(self):
        res = parse_isnad(BUKHARI_2, book="bukhari", hadith_number="2")
        self.assertIn("عبد الله بن يوسف", norms(res))
        self.assertIn("مالك", norms(res))          # single word -> review
        self.assertIn("هشام بن عروه", norms(res))
        self.assertIn("ابيه", norms(res))          # relative reference
        aisha = by_norm(res, "عايشه ام المومنين")
        self.assertIsNotNone(aisha)
        self.assertTrue(aisha.companion_marked)
        # الحارث بن هشام asked the Prophet: matn subject, not a narrator.
        self.assertNotIn("الحارث بن هشام", norms(res))
        self.assertTrue(res.isnad_complete)
        rel = by_norm(res, "ابيه")
        self.assertEqual(rel.confidence, "needs_review")
        self.assertIn("relative_reference", rel.flags)

    def test_bukhari_4_starts_with_qala(self):
        res = parse_isnad(BUKHARI_4, book="bukhari", hadith_number="4")
        self.assertIn("ابن شهاب", norms(res))
        self.assertIn("ابو سلمه بن عبد الرحمن", norms(res))
        self.assertIn("جابر بن عبد الله الانصاري", norms(res))
        ibn_shihab = by_norm(res, "ابن شهاب")
        self.assertEqual(ibn_shihab.confidence, "needs_review")
        self.assertIn("partial_name", ibn_shihab.flags)
        self.assertTrue(res.isnad_complete)


class TestMuslimSamples(unittest.TestCase):
    def test_muslim_3_yani_clarification(self):
        res = parse_isnad(MUSLIM_3, book="muslim", hadith_number="3")
        self.assertEqual(
            norms(res),
            ["زهير بن حرب", "اسماعيل ابن عليه",
             "عبد العزيز بن صهيب", "انس بن مالك"])
        ismail = res.narrators[1]
        self.assertEqual(ismail.clarification, "ابْنَ عُلَيَّةَ")
        self.assertIn("yani_clarification", ismail.flags)
        self.assertEqual(ismail.confidence, "needs_review")
        self.assertIn("yani_clarification",
                      [i["code"] for i in res.review_items])
        self.assertTrue(res.isnad_complete)

    def test_muslim_93_tahwil_two_chains(self):
        res = parse_isnad(MUSLIM_93, book="muslim", hadith_number="93")
        self.assertEqual(len(res.chains), 2)
        self.assertEqual(res.chains[0].chain_index, 0)
        self.assertEqual(res.chains[1].chain_index, 1)
        self.assertFalse(res.chains[1].is_primary)
        # Apposition across the comma: أبو خيثمة IS زهير بن حرب — one span.
        self.assertIn("ابو خيثمه زهير بن حرب", norms(res))
        self.assertIn("وكيع", norms(res))
        self.assertIn("كهمس", norms(res))
        self.assertIn("عبد الله بن بريده", norms(res))
        self.assertIn("يحيي بن يعمر", norms(res))
        self.assertIn("عبيد الله بن معاذ العنبري", norms(res))
        self.assertIn("ابي", norms(res))           # حدثنا أبي — relative
        self.assertIn("ابن بريده", norms(res))     # partial name
        self.assertIn("chain_break_tahwil",
                      [i["code"] for i in res.review_items])
        self.assertTrue(all(n.narrator_id is None for n in res.narrators))


class TestAhmadSamples(unittest.TestCase):
    def test_ahmad_2_co_narrators(self):
        res = parse_isnad(AHMAD_2, book="ahmad", hadith_number="2")
        self.assertEqual(
            norms(res),
            ["وكيع", "مسعر", "سفيان", "عثمان بن المغيره الثقفي",
             "علي بن ربيعه الوالبي", "اسماء بن الحكم الفزاري", "علي"])
        # مسعر and سفيان are parallel narrators: same position.
        self.assertEqual(res.narrators[1].position,
                         res.narrators[2].position)
        self.assertEqual(res.narrators[2].link_type, "co_narrator")
        self.assertIn("co_narrator_split",
                      [i["code"] for i in res.review_items])
        ali = res.narrators[-1]
        self.assertTrue(ali.companion_marked)
        self.assertEqual(ali.confidence, "medium")
        self.assertTrue(res.isnad_complete)

    def test_ahmad_1_yani_and_matn_verb_boundary(self):
        res = parse_isnad(AHMAD_1, book="ahmad", hadith_number="1")
        self.assertEqual(
            norms(res),
            ["عبد الله بن نمير", "اسماعيل ابن ابي خالد", "قيس"])
        ismail = res.narrators[1]
        self.assertEqual(ismail.clarification, "ابن أبي خالد")
        self.assertIn("yani_clarification", ismail.flags)
        # أبو بكر stood and praised God: matn content, not a narrator.
        self.assertNotIn("ابو بكر", norms(res))
        self.assertTrue(res.isnad_complete)
        self.assertFalse(res.companion_marked)

    def test_ahmad_3_yani_nisba(self):
        res = parse_isnad(AHMAD_3, book="ahmad", hadith_number="3")
        self.assertIn("عمرو بن محمد ابو سعيد العنقزي", norms(res))
        self.assertIn("اسراييل", norms(res))
        self.assertIn("ابو اسحاق", norms(res))     # kunya only -> review
        self.assertIn("البراء بن عازب", norms(res))
        self.assertNotIn("ابو بكر", norms(res))    # matn subject (اشترى)
        abu_ishaq = by_norm(res, "ابو اسحاق")
        self.assertEqual(abu_ishaq.confidence, "needs_review")
        self.assertIn("kunya_only", abu_ishaq.flags)

    def test_ahmad_4_double_qala(self):
        res = parse_isnad(AHMAD_4, book="ahmad", hadith_number="4")
        self.assertEqual(
            norms(res),
            ["وكيع", "اسراييل", "ابو اسحاق", "زيد بن يثيع", "ابو بكر"])
        self.assertTrue(res.isnad_complete)
        self.assertEqual(res.boundary_reason, "matn_after_anna")

    def test_ahmad_5_single_word_and_matn_verb(self):
        res = parse_isnad(AHMAD_5, book="ahmad", hadith_number="5")
        self.assertIn("محمد بن جعفر", norms(res))
        self.assertIn("شعبه", norms(res))
        self.assertIn("يزيد بن خمير", norms(res))
        self.assertIn("سليم بن عامر", norms(res))
        self.assertIn("اوسط", norms(res))          # single word -> review
        self.assertEqual(by_norm(res, "اوسط").confidence, "needs_review")
        # خطبنا أبو بكر: matn, not a narrator.
        self.assertNotIn("ابو بكر", norms(res))


class TestAmbiguityAndNoLinking(unittest.TestCase):
    def test_sufyan_thawri_vs_ibn_uyayna_is_ambiguity_not_a_link(self):
        # A bare «سفيان» — the classic ambiguity (الثوري vs ابن عيينة).
        text = ("حدثنا سفيان قال حدثنا يحيى بن سعيد الأنصاري عن محمد بن "
                "إبراهيم التيمي أنه سمع علقمة بن وقاص الليثي يقول سمعت عمر "
                "بن الخطاب رضي الله عنه قال سمعت رسول الله صلى الله عليه "
                "وسلم يقول إنما الأعمال بالنيات")
        res = parse_isnad(text)
        sufyan = by_norm(res, "سفيان")
        self.assertIsNotNone(sufyan)
        self.assertEqual(sufyan.confidence, "needs_review")
        self.assertIsNone(sufyan.narrator_id)
        self.assertEqual(sufyan.match_status, "needs_review")
        # The full name is a DIFFERENT candidate span — never merged.
        text2 = ("حدثنا سفيان بن عيينة قال حدثنا يحيى بن سعيد الأنصاري عن "
                 "محمد بن إبراهيم التيمي أنه سمع علقمة بن وقاص الليثي يقول "
                 "سمعت عمر بن الخطاب رضي الله عنه قال سمعت رسول الله صلى "
                 "الله عليه وسلم يقول إنما الأعمال بالنيات")
        res2 = parse_isnad(text2)
        full = by_norm(res2, "سفيان بن عيينه")
        self.assertIsNotNone(full)
        self.assertEqual(full.confidence, "high")
        self.assertIsNone(full.narrator_id)
        self.assertNotEqual(sufyan.narrator_norm, full.narrator_norm)

    def test_resolve_identity_never_links_without_a_verified_source(self):
        self.assertEqual(
            resolve_identity("سفيان")["decision"], "unlinked")
        self.assertIsNone(resolve_identity("سفيان")["narrator_id"])
        # Even with a supplied verified list, a bare name matching two
        # rows is ambiguous and is NOT linked.
        verified = [
            {"id": 1, "name": "سفيان الثوري"},
            {"id": 2, "name": "سفيان بن عيينة"},
        ]
        decision = resolve_identity("سفيان", verified_narrators=verified)
        self.assertEqual(decision["decision"], "ambiguous")
        self.assertIsNone(decision["narrator_id"])

    def test_yani_does_not_create_a_second_narrator(self):
        res = parse_isnad(AHMAD_1)
        self.assertEqual(len(res.narrators), 3)
        self.assertEqual(res.narrators[1].narrator_norm,
                         "اسماعيل ابن ابي خالد")

    def test_companion_radiya_marks_companion(self):
        res = parse_isnad(AHMAD_2)
        self.assertTrue(res.companion_marked)
        self.assertTrue(res.narrators[-1].companion_marked)

    def test_no_linking_on_ambiguity_even_for_famous_kunya(self):
        res = parse_isnad(
            "حدثنا أبو هريرة قال قال رسول الله صلى الله عليه وسلم ...")
        abu = res.narrators[0]
        self.assertEqual(abu.narrator_norm, "ابو هريره")
        self.assertEqual(abu.confidence, "needs_review")
        self.assertIsNone(abu.narrator_id)

    def test_matn_verb_laqina_is_not_a_narrator(self):
        # Muslim 95 pattern: «قالا: لقينا عبد الله بن عمر فذكرنا
        # القدر وما ...» — لقينا (we met) is a matn verb, not a name,
        # and وما is a particle, not a name word.
        res = parse_isnad(
            "حدثني محمد بن حاتم، حدثنا يحيى بن سعيد القطان، حدثنا عثمان "
            "بن غياث، حدثنا عبد الله بن بريدة، عن يحيى بن يعمر، وحميد "
            "بن عبد الرحمن، قالا: لقينا عبد الله بن عمر فذكرنا القدر "
            "وما فيه من الخير والشر")
        self.assertNotIn("لقينا عبد الله بن عمر فذكرنا القدر وما",
                         norms(res))
        self.assertNotIn("لقينا", norms(res))
        self.assertIn("حميد بن عبد الرحمن", norms(res))
        self.assertTrue(res.isnad_complete)

    def test_ibn_wahb_is_one_name(self):
        # «أخبرنا ابن وهب» — وهب is a genuine و-initial name, the
        # father's name after ابن; it must not split into ابن + هب.
        res = parse_isnad(
            "حدثني أبو الطاهر، أحمد بن عمرو بن عبد الله بن عمرو بن سرح "
            "وحرملة بن يحيى التجيبي قالا أخبرنا ابن وهب، عن يونس، عن "
            "ابن شهاب، أن عطاء بن يزيد الليثي قال قال رسول الله صلى "
            "الله عليه وسلم ...")
        self.assertIn("ابن وهب", norms(res))
        self.assertNotIn("ابن", norms(res))
        self.assertNotIn("هب", norms(res))


class TestDegenerateInputs(unittest.TestCase):
    def test_empty_text(self):
        res = parse_isnad("")
        self.assertEqual(res.narrators, [])
        self.assertEqual(res.isnad_status, "none")
        self.assertFalse(res.isnad_complete)

    def test_matn_only_muallaq_style(self):
        res = parse_isnad(
            "قال رسول الله صلى الله عليه وسلم إنما الأعمال بالنيات")
        self.assertEqual(res.narrators, [])
        self.assertEqual(res.isnad_status, "none")

    def test_relative_reference_father(self):
        res = parse_isnad(
            "حدثنا أبي حدثنا كهمس عن عبد الله بن بريدة عن يحيى بن يعمر "
            "قال لما تكلم معبد")
        first = res.narrators[0]
        self.assertEqual(first.narrator_norm, "ابي")
        self.assertEqual(first.confidence, "needs_review")
        self.assertIn("relative_reference", first.flags)
        self.assertIsNone(first.narrator_id)

    def test_parser_never_judges_authenticity(self):
        res = parse_isnad(BUKHARI_1)
        dump = json.dumps(res.to_dict(), ensure_ascii=False)
        self.assertNotIn("sahih", dump)
        self.assertNotIn("authentic", dump)
        self.assertNotIn("grade", dump)
        self.assertNotIn("is_authentic", dump)

    def test_confidence_arabic_labels_cover_all_levels(self):
        self.assertEqual(
            set(CONFIDENCE_AR.values()),
            {"عالية", "متوسطة", "منخفضة", "يحتاج مراجعة"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
