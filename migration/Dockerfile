FROM python:3.14-alpine
COPY requirements.txt /requirements.txt
RUN pip install --no-cache-dir --require-hashes -r /requirements.txt
COPY migrate_kaidoho.py /migrate_kaidoho.py
# The report is written to the working directory: mount somewhere here, e.g. -v "$PWD:/out".
WORKDIR /out
ENTRYPOINT ["python", "/migrate_kaidoho.py"]
