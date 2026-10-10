"""Render one workroom question from the same structured record used by the portal."""

import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import HRFlowable, Paragraph, SimpleDocTemplate, Spacer


def register_font():
    unicode_font = Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
    if unicode_font.exists():
        pdfmetrics.registerFont(TTFont("WorkroomBody", str(unicode_font)))
        return "WorkroomBody"

    import reportlab

    vera = Path(reportlab.__file__).parent / "fonts" / "Vera.ttf"
    pdfmetrics.registerFont(TTFont("WorkroomBody", str(vera)))
    return "WorkroomBody"


def paragraph(value, style):
    return Paragraph(escape(str(value)).replace("\n", "<br/>"), style)


def render(record, output):
    room = record["room"]
    question = record["question"]
    presentation = question.get("presentation") or {}
    font = register_font()
    ink = colors.HexColor("#182431")
    quiet = colors.HexColor("#526474")
    accent = colors.HexColor("#155e74")
    styles = {
        "eyebrow": ParagraphStyle("eyebrow", fontName="Helvetica-Bold", fontSize=9,
                                  leading=12, textColor=accent, spaceAfter=8),
        "title": ParagraphStyle("title", fontName=font, fontSize=19, leading=25,
                                textColor=ink, spaceAfter=12),
        "question": ParagraphStyle("question", fontName=font, fontSize=13, leading=19,
                                   textColor=ink, spaceAfter=14),
        "heading": ParagraphStyle("heading", fontName="Helvetica-Bold", fontSize=9,
                                  leading=13, textColor=accent, spaceBefore=17, spaceAfter=7),
        "body": ParagraphStyle("body", fontName=font, fontSize=10.5, leading=16,
                               textColor=ink, spaceAfter=8, alignment=TA_LEFT),
        "small": ParagraphStyle("small", fontName=font, fontSize=8.5, leading=13,
                                textColor=quiet, spaceAfter=6),
        "choice": ParagraphStyle("choice", fontName=font, fontSize=10.5, leading=16,
                                 leftIndent=18, firstLineIndent=-18, textColor=ink, spaceAfter=8),
    }
    document = SimpleDocTemplate(str(output), pagesize=A4, rightMargin=54, leftMargin=54,
                                 topMargin=54, bottomMargin=58, title=f"{room['title']} - question",
                                 author="Linked Workrooms")
    story = [
        Paragraph("LINKED WORKROOMS", styles["eyebrow"]),
        paragraph(room["title"], styles["title"]),
        paragraph(room.get("purpose") or "", styles["small"]),
        Spacer(1, 10),
        HRFlowable(width="100%", thickness=1, color=colors.HexColor("#ced9df")),
        Spacer(1, 16),
        Paragraph("QUESTION", styles["eyebrow"]),
        paragraph(question["text"], styles["question"]),
        paragraph("Status: answered" if question.get("answer") is not None else "Status: awaiting answer", styles["small"]),
    ]
    if presentation:
        story.extend([Paragraph("BACKGROUND", styles["heading"]),
                      paragraph(presentation["context"], styles["body"])])
        if presentation.get("choices"):
            story.append(Paragraph("POSSIBLE PATHS", styles["heading"]))
            for index, choice in enumerate(presentation["choices"], 1):
                story.append(paragraph(f"{index}. {choice}", styles["choice"]))
        if presentation.get("sources"):
            story.append(Paragraph("SOURCE NOTES TO VERIFY", styles["heading"]))
            for source in presentation["sources"]:
                story.append(paragraph(source, styles["body"]))
    if question.get("answer") is not None:
        story.extend([Paragraph("ANSWER", styles["heading"]),
                      paragraph(question["answer"], styles["body"]),
                      paragraph(f"Answered by {question.get('answeredBy') or 'unknown'}", styles["small"])])
    else:
        story.extend([Spacer(1, 12), paragraph("This copy does not accept answers. Reply in the workroom using your private invitation.", styles["small"])])
    story.extend([Spacer(1, 18),
                  paragraph(f"Room {room['id']}  |  Question {question['id']}", styles["small"]),
                  paragraph(f"Snapshot generated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}", styles["small"])])

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setStrokeColor(colors.HexColor("#ced9df"))
        canvas.line(54, 42, A4[0] - 54, 42)
        canvas.setFont("Helvetica", 8)
        canvas.setFillColor(quiet)
        canvas.drawString(54, 29, "Linked Workrooms - question snapshot")
        canvas.drawRightString(A4[0] - 54, 29, f"Page {doc.page}")
        canvas.restoreState()

    document.build(story, onFirstPage=footer, onLaterPages=footer)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: render_pdf.py RECORD_JSON OUTPUT_PDF")
    render(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")), Path(sys.argv[2]))
