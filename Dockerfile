FROM python:slim
LABEL maintainer="Perdy <perdy@perdy.io>"

ENV PYTHONPATH=$APPDIR:$PYTHONPATH

ENV BUILD_PACKAGES="curl build-essential git"

COPY requirements.txt $APPDIR/

RUN apt-get update && \
    apt-get install -y $BUILD_PACKAGES && \
    # Install docker
    curl -fsSL https://get.docker.com | sh && \
    # Install kubectl
    curl -o /usr/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl && \
    chmod +x /usr/bin/kubectl && \
    # Install aws-iam-authenticator
    curl -o /usr/bin/aws-iam-authenticator https://amazon-eks.s3-us-west-2.amazonaws.com/1.10.3/2018-07-26/bin/linux/amd64/aws-iam-authenticator && \
    chmod +x /usr/bin/aws-iam-authenticator && \
    # Install python requirements
    python -m pip install --no-cache-dir --upgrade pip poetry && \
    python -m pip install --no-cache-dir -r requirements.txt && \
    # Clean
    apt-get clean && \
    rm -rf \
        requirements.txt \
        /tmp/* \
        /var/tmp/*

# Copy build script
COPY builder /usr/local/bin
