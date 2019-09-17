#!/usr/bin/env python3
"""Run script.
"""
import base64
import logging
import shlex
import subprocess
import sys
import tempfile
import os
import typing
from urllib.parse import urlparse

import boto3
import jinja2
import requests
from clinner.command import Type, command
from clinner.run.main import Main

logger = logging.getLogger("cli")


class TemporaryRemoteFile:
    CHUNK_SIZE = 10000

    def __init__(self, uri: str):
        """
        Creates a temporary copy of a file from a local path or remote URI.

        :param uri: File local path or remote URI.
        """
        self.uri = urlparse(uri)
        self._file = tempfile.NamedTemporaryFile()

    def _get_content_from_file(self) -> typing.Generator[bytes, typing.Any, None]:
        with open(self.uri.geturl(), "rb") as file:
            return (i for i in file.read())

    def _get_content_from_http(self) -> typing.Generator[bytes, typing.Any, None]:
        with requests.get(self.uri.geturl(), stream=True) as file:
            return file.iter_content()

    def _get_content_from_s3(self) -> typing.Generator[bytes, typing.Any, None]:
        bucket = boto3.resource("s3").Object(bucket_name=self.uri.netloc, key=self.uri.path.lstrip("/"))
        return bucket.get()["Body"]

    def get_content(self) -> typing.Generator[bytes, typing.Any, None]:
        if self.uri.scheme == "":
            return self._get_content_from_file()
        elif self.uri.scheme in ("http", "https"):
            return self._get_content_from_http()
        elif self.uri.scheme == "s3":
            return self._get_content_from_s3()
        else:
            raise ValueError(f"Unknown URI scheme for {self.uri}")

    def __enter__(self):
        if self._file.closed:
            raise ValueError("Cannot enter context with closed file")

        self._file.__enter__()

        with open(self._file.name, "wb") as file:
            for byte in self.get_content():
                file.write(byte)

        return self._file

    def __exit__(self, exc_type, exc_val, exc_tb):
        self._file.__exit__(exc_type, exc_val, exc_tb)


@command(
    command_type=Type.SHELL_WITH_HELP,
    args=(
        (("-t", "--tag"), {"help": "Docker image tag", "required": True}),
        (("--extra-tag",), {"help": "Create additional tags", "action": "append"}),
        (("--cache-from",), {"help": "Docker cache file to read"}),
        (("--store-image",), {"help": "Path to store Docker image"}),
    ),
    parser_opts={"help": "Build docker image"},
)
def build(*args, **kwargs) -> typing.List[typing.List[str]]:
    cmds = []

    # Load cached image if proceed and build
    if kwargs["cache_from"] and os.path.exists(kwargs["cache_from"]):
        logger.info("Loading docker image from %s", kwargs["cache_from"])
        cmds += load(file=kwargs["cache_from"])

    cmds += [shlex.split(f"docker build -t {kwargs['tag']} .") + list(args)]

    # Extra tags
    if kwargs["extra_tag"]:
        cmds += tag(tag=kwargs["tag"], new_tag=kwargs["extra_tag"])

    # Cache built image
    if kwargs["store_image"]:
        logger.info("Saving docker image to %s", kwargs["store_image"])
        cmds += save(tag=kwargs["tag"], file=kwargs["store_image"])

    return cmds


@command(
    command_type=Type.SHELL_WITH_HELP,
    args=((("tag",), {"help": "Docker image tag"}), (("new_tag",), {"help": "New tag", "nargs": "+"})),
    parser_opts={"help": "Tag docker image"},
)
def tag(*args, **kwargs) -> typing.List[typing.List[str]]:
    return [shlex.split(f"docker tag {kwargs['tag']} {t}") for t in kwargs["new_tag"]]


@command(
    command_type=Type.SHELL_WITH_HELP,
    args=((("tag",), {"help": "Docker image tag"}), (("file",), {"help": "File path"})),
    parser_opts={"help": "Save docker image to file"},
)
def save(*args, **kwargs) -> typing.List[typing.List[str]]:
    os.makedirs(os.path.dirname(kwargs["file"]), exist_ok=True)
    return [shlex.split(f"docker save -o {kwargs['file']} {kwargs['tag']}")]


@command(
    command_type=Type.SHELL_WITH_HELP,
    args=((("file",), {"help": "File path"}),),
    parser_opts={"help": "Load docker image from file"},
)
def load(*args, **kwargs) -> typing.List[typing.List[str]]:
    if os.path.exists(kwargs["file"]):
        return [shlex.split(f"docker load -i {kwargs['file']}")]

    logger.error("File not found: %s", kwargs["file"])
    return []


@command(
    command_type=Type.SHELL_WITH_HELP,
    args=(
        (("-t", "--tag"), {"help": "Tags to push", "action": "append"}),
        (("-u", "--username"), {"help": "Docker Hub username"}),
        (("-p", "--password"), {"help": "Docker Hub password"}),
        (("--aws-ecr",), {"help": "Login to AWS ECR", "action": "store_true"}),
    ),
    parser_opts={"help": "Push docker image"},
)
def push(*args, **kwargs) -> typing.List[typing.List[str]]:
    cmds = []

    # Login to AWS ECR using aws credentials
    if kwargs["aws_ecr"]:
        ecr_client = boto3.client("ecr")
        token = ecr_client.get_authorization_token()["authorizationData"][0]
        username, password = base64.b64decode(token["authorizationToken"]).decode().split(":")
        url = token["proxyEndpoint"]
        cmds += [shlex.split(f"docker login -u {username} -p {password} {url}")]

    # Login to Docker hub
    if kwargs["username"] and kwargs["password"]:
        cmds += [shlex.split(f"docker login -u {kwargs['username']} -p {kwargs['password']}")]

    # Push tags
    cmds += [shlex.split(f"docker push {t}") + list(args) for t in kwargs["tag"]]

    return cmds


@command(
    command_type=Type.PYTHON,
    args=(
        (
            ("manifest",),
            {
                "help": "Directory or list of directories where the k8s manifests are located. Manifests are jinja2 "
                "templates and will be rendered before applying",
                "nargs": "+",
            },
        ),
        (("-c", "--config"), {"help": "Kubectl config file"}),
    ),
    parser_opts={"help": "Deploy to kubernetes processing manifest files and applying them using kubectl."},
)
def kubernetes_deploy(*args, **kwargs):
    env = jinja2.Environment(loader=jinja2.FileSystemLoader(kwargs["manifest"]))
    manifests = env.list_templates(
        filter_func=lambda x: "/" not in x and "." in x and x.rsplit(".", 1)[1] in ("json", "yaml", "yml")
    )

    if not manifests:
        raise FileNotFoundError(f"No manifests were found")

    logger.info("Collected manifests: %s", ", ".join(manifests))
    with tempfile.TemporaryDirectory() as tmpdir:
        for manifest in manifests:
            with open(os.path.join(tmpdir, manifest), "w") as out:
                logger.info("Rendering manifest %s", manifest)
                out.write(env.get_template(manifest).render(env=os.environ))

        # Apply all manifests
        cmd = shlex.split(f"kubectl apply -v 3 -o yaml -f {tmpdir}")
        if kwargs["config"]:
            cmd.insert(1, "--kubeconfig")
            cmd.insert(2, kwargs["config"])

        subprocess.run(cmd)


class Builder(Main):
    def add_arguments(self, parser: "argparse.ArgumentParser"):
        verbose_group = parser.add_mutually_exclusive_group()
        verbose_group.add_argument(
            "-q", "--quiet", action="store_true", help="Quiet mode. No standard output other than executed application"
        )
        verbose_group.add_argument(
            "-v", "--verbose", action="count", default=1, help="Verbose level (This option is additive)"
        )


if __name__ == "__main__":
    sys.exit(Builder().run())
