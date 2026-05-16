"""
Invoice Service (Python / Flask)

Generates a full-page invoice PDF on demand. Bill-to and line items can be
supplied as query parameters; sensible defaults are used otherwise so the
simple curl always produces a believable invoice.

Endpoints:
  GET /generate?name=Acme&item=desc:qty:unit&item=...
      -> downloadable invoice PDF. All params optional.
  GET /example
      -> JSON describing the input format and current defaults
  GET /health
      -> {"status": "ok"}
"""

import os
import random
import tempfile
from datetime import date, timedelta

from flask import Flask, after_this_request, jsonify, request, send_file
from fpdf import FPDF

app = Flask(__name__)

PORT = int(os.getenv("PORT", "8081"))


def _latin1_safe(s: str) -> str:
    """fpdf 1.x can only encode Latin-1 characters. Replace common Unicode
    punctuation with safe equivalents, then drop anything else that's still
    out of range. Keeps the PDF rendering even when ?name= contains an
    emoji or some other surprise."""
    replacements = {
        "\u2014": "-",   # em dash
        "\u2013": "-",   # en dash
        "\u2018": "'",   # left single quote
        "\u2019": "'",   # right single quote
        "\u201C": '"',   # left double quote
        "\u201D": '"',   # right double quote
        "\u2026": "...", # ellipsis
        "\u00A0": " ",   # non-breaking space
    }
    for src, dst in replacements.items():
        s = s.replace(src, dst)
    return s.encode("latin-1", errors="replace").decode("latin-1")


# The "from" side of every invoice. This stays constant - the demo is the
# invoice-service issuing invoices to whichever client name comes in.
ISSUER = {
    "name":    "Northwind Web Services",
    "address": "118 Allen St, Buffalo, NY 14202",
    "email":   "billing@northwind.example",
}

# A believable fixed set of line items. The mix is deliberate: a few
# hourly lines, a flat fee, and a small misc charge - enough variety to
# fill a real-looking invoice.
LINE_ITEMS = [
    # (description, quantity, unit_price_usd)
    ("Backend engineering - sprint 14",      40, 125.00),
    ("Frontend engineering - sprint 14",     24, 110.00),
    ("Code review and pair sessions",         6, 140.00),
    ("Production incident response (1 event)", 1, 850.00),
    ("Hosting passthrough (Nov 2025)",        1, 312.40),
]

TAX_RATE = 0.0875  # NY state-and-local sample rate
PAYMENT_TERMS_DAYS = 30


def parse_items_from_query(raw_items):
    """Parse a list of 'description:qty:unit' strings into invoice line items.

    Returns a list of (description, qty, unit_price) tuples. Raises ValueError
    with a human-readable message if any item is malformed.
    """
    parsed = []
    for raw in raw_items:
        # rsplit so descriptions containing ':' work as long as qty and unit
        # are the last two fields. (e.g. "Web work: backend:40:125")
        parts = raw.rsplit(":", 2)
        if len(parts) != 3:
            raise ValueError(
                f"item '{raw}' must look like 'description:qty:unit_price' "
                "(three colon-separated parts)"
            )
        description, qty_str, unit_str = parts[0].strip(), parts[1].strip(), parts[2].strip()
        if not description:
            raise ValueError(f"item '{raw}' is missing a description")
        try:
            qty = int(qty_str)
        except ValueError:
            raise ValueError(f"item '{raw}': qty '{qty_str}' is not an integer")
        try:
            unit = float(unit_str)
        except ValueError:
            raise ValueError(f"item '{raw}': unit '{unit_str}' is not a number")
        if qty <= 0 or unit < 0:
            raise ValueError(f"item '{raw}': qty must be positive and unit non-negative")
        parsed.append((_latin1_safe(description), qty, unit))
    return parsed


def build_invoice_pdf(bill_to: str, output_path: str, items=None) -> None:
    """Render the invoice to `output_path`.

    If `items` is None or empty, the default LINE_ITEMS are used. Otherwise
    `items` should be an iterable of (description, qty, unit_price) tuples.
    """
    if not items:
        items = LINE_ITEMS

    pdf = FPDF()
    pdf.add_page()
    pdf.set_margins(left=18, top=18, right=18)

    # --- Header band ---------------------------------------------------------
    pdf.set_font("Arial", "B", 24)
    pdf.cell(0, 12, "INVOICE", ln=1)

    pdf.set_font("Arial", "", 10)
    pdf.set_text_color(110, 110, 110)
    pdf.cell(0, 5, ISSUER["name"], ln=1)
    pdf.cell(0, 5, ISSUER["address"], ln=1)
    pdf.cell(0, 5, ISSUER["email"], ln=1)
    pdf.set_text_color(0, 0, 0)
    pdf.ln(8)

    # --- Bill-to + invoice meta (two columns) -------------------------------
    today = date.today()
    due   = today + timedelta(days=PAYMENT_TERMS_DAYS)
    invoice_no = f"INV-{today.strftime('%Y%m')}-{random.randint(1000, 9999)}"

    col_y = pdf.get_y()
    # Left column: bill to
    pdf.set_font("Arial", "B", 10)
    pdf.cell(90, 6, "BILL TO", ln=2)
    pdf.set_font("Arial", "", 11)
    pdf.cell(90, 6, bill_to, ln=2)
    pdf.set_font("Arial", "", 10)
    pdf.set_text_color(110, 110, 110)
    pdf.cell(90, 5, "Attn: Accounts Payable", ln=2)
    pdf.set_text_color(0, 0, 0)

    # Right column: invoice metadata. Move cursor back up and over.
    right_x = 110
    pdf.set_xy(right_x, col_y)
    pdf.set_font("Arial", "B", 10)
    pdf.cell(40, 6, "Invoice #")
    pdf.set_font("Arial", "", 10)
    pdf.cell(0, 6, invoice_no, ln=1)

    pdf.set_x(right_x)
    pdf.set_font("Arial", "B", 10)
    pdf.cell(40, 6, "Issued")
    pdf.set_font("Arial", "", 10)
    pdf.cell(0, 6, today.strftime("%B %d, %Y"), ln=1)

    pdf.set_x(right_x)
    pdf.set_font("Arial", "B", 10)
    pdf.cell(40, 6, "Due")
    pdf.set_font("Arial", "", 10)
    pdf.cell(0, 6, due.strftime("%B %d, %Y"), ln=1)

    pdf.ln(10)

    # --- Line item table ----------------------------------------------------
    # Column widths: description / qty / unit / line total
    col_w = (98, 18, 28, 30)
    pdf.set_fill_color(245, 245, 245)
    pdf.set_font("Arial", "B", 10)
    pdf.cell(col_w[0], 8, "DESCRIPTION", border=0, fill=True)
    pdf.cell(col_w[1], 8, "QTY", border=0, align="R", fill=True)
    pdf.cell(col_w[2], 8, "UNIT", border=0, align="R", fill=True)
    pdf.cell(col_w[3], 8, "AMOUNT", border=0, align="R", fill=True, ln=1)

    pdf.set_font("Arial", "", 10)
    subtotal = 0.0
    for description, qty, unit in items:
        amount = qty * unit
        subtotal += amount
        pdf.cell(col_w[0], 8, description, border="B")
        pdf.cell(col_w[1], 8, str(qty),                  border="B", align="R")
        pdf.cell(col_w[2], 8, f"${unit:,.2f}",           border="B", align="R")
        pdf.cell(col_w[3], 8, f"${amount:,.2f}",         border="B", align="R", ln=1)

    pdf.ln(6)

    # --- Totals (right-aligned block) ---------------------------------------
    tax = round(subtotal * TAX_RATE, 2)
    total = round(subtotal + tax, 2)

    totals_label_w = sum(col_w[:3])
    totals_val_w   = col_w[3]

    pdf.set_font("Arial", "", 10)
    pdf.cell(totals_label_w, 7, "Subtotal", align="R")
    pdf.cell(totals_val_w,   7, f"${subtotal:,.2f}", align="R", ln=1)

    pdf.cell(totals_label_w, 7, f"Tax ({TAX_RATE*100:.2f}%)", align="R")
    pdf.cell(totals_val_w,   7, f"${tax:,.2f}", align="R", ln=1)

    pdf.set_font("Arial", "B", 11)
    pdf.cell(totals_label_w, 9, "Total due", align="R")
    pdf.cell(totals_val_w,   9, f"${total:,.2f}", align="R", ln=1)

    pdf.ln(12)

    # --- Payment terms + footer ---------------------------------------------
    pdf.set_font("Arial", "B", 10)
    pdf.cell(0, 6, "Payment terms", ln=1)
    pdf.set_font("Arial", "", 10)
    pdf.multi_cell(
        0, 5,
        f"Net {PAYMENT_TERMS_DAYS}. Payment is due by {due.strftime('%B %d, %Y')}. "
        "Bank details available on request. A late fee of 1.5% per month may "
        "apply to balances unpaid after the due date."
    )

    pdf.ln(6)
    pdf.set_font("Arial", "I", 9)
    pdf.set_text_color(140, 140, 140)
    pdf.cell(0, 5, "Generated by invoice-service in the microservices demo suite.", ln=1, align="C")

    pdf.output(output_path)


@app.route("/generate")
def generate_invoice():
    bill_to = _latin1_safe(request.args.get("name", "Sample Client, Inc."))

    raw_items = request.args.getlist("item")
    try:
        items = parse_items_from_query(raw_items) if raw_items else None
    except ValueError as e:
        return jsonify(error="invalid item format", detail=str(e)), 400

    fd, tmp_path = tempfile.mkstemp(prefix="invoice_", suffix=".pdf")
    os.close(fd)
    build_invoice_pdf(bill_to, tmp_path, items=items)

    @after_this_request
    def cleanup(response):
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        return response

    safe_filename = "".join(c if c.isalnum() else "_" for c in bill_to)[:40] or "invoice"
    return send_file(
        tmp_path,
        mimetype="application/pdf",
        as_attachment=True,
        download_name=f"invoice_{safe_filename}.pdf",
    )


@app.route("/example")
def example():
    """Document the invoice input format so users know what to pass."""
    return jsonify(
        format={
            "name": "(optional) the bill-to company or person",
            "item": "(optional, repeatable) 'description:qty:unit_price'",
        },
        sample_curl=(
            'curl "http://localhost:8080/generate'
            "?name=Acme%20Corp"
            "&item=Backend%20engineering:40:125"
            "&item=Frontend%20engineering:24:110"
            '" -o invoice.pdf'
        ),
        notes=[
            "All params are optional. With none, the default invoice is generated.",
            "URL-encode spaces (use %20) and any special characters in descriptions.",
            "qty must be a positive integer; unit_price can be any non-negative number.",
            "Issuer info, dates, invoice number, tax rate, and payment terms are fixed.",
        ],
        defaults={
            "issuer": ISSUER,
            "tax_rate_pct": TAX_RATE * 100,
            "payment_terms_days": PAYMENT_TERMS_DAYS,
            "items": [
                {"description": d, "qty": q, "unit_price_usd": u}
                for d, q, u in LINE_ITEMS
            ],
        },
    )


@app.route("/health")
def health():
    return jsonify(status="ok"), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)