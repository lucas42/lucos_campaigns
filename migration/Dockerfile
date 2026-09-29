FROM python:3.13-alpine
RUN pip install --no-cache-dir requests==2.32.5
COPY migrate_kaidoho.py /migrate_kaidoho.py
ENTRYPOINT ["python", "/migrate_kaidoho.py"]
