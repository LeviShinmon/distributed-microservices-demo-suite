from flask import Flask, request, send_file
from fpdf import FPDF

app = Flask(__name__)

@app.route('/generate')
def create_doc():
    name = request.args.get('name', 'User')
    pdf = FPDF()
    pdf.add_page()
    pdf.set_font("Arial", size=12)
    pdf.cell(200, 10, txt=f"Service Report: {name}", ln=1, align='C')
    
    output = f"doc_{name}.pdf"
    pdf.output(output)
    return send_file(output)[cite: 2]

if __name__ == '__main__':
    app.run(port=8081)
