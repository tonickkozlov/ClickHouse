#!/usr/bin/env python

import argparse
import base64
import os
import subprocess
from pathlib import Path

CCACHE_ACCESS_KEY = os.environ.get("CCACHE_ACCESS_KEY", "")
CCACHE_SECRET_KEY = os.environ.get("CCACHE_SECRET_KEY", "")
S3_CCACHE_KEY_SUFFIX = os.environ.get("S3_CCACHE_KEY_SUFFIX", "default")
HOME = str(Path.home())


def git_branch():
    return subprocess.run(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], check=True,
                          stdout=subprocess.PIPE).stdout.decode('utf-8').strip()


def ccache_read_keys():
    # Avoid reading ccache for production builds. Paranoid.
    if git_branch().startswith('cf/v'):
        return []

    return [
        git_branch() + "+" + S3_CCACHE_KEY_SUFFIX,
        "cf/v20.8+" + S3_CCACHE_KEY_SUFFIX
    ]


def ccache_write_keys():
    return [git_branch() + "+" + S3_CCACHE_KEY_SUFFIX]


def str_b64e(s):
    return base64.b64encode(s.encode('utf-8')).decode('utf-8')


def setup_env():
    with open(HOME + "/.aws/credentials", "w") as f:
        f.write("""[default]
aws_access_key_id = {}
aws_secret_access_key = {}
s3 =
    signature_version = s3""".format(CCACHE_ACCESS_KEY, CCACHE_SECRET_KEY))


def download_ccache():
    print('will probe keys: ', ccache_read_keys())

    good_key = None
    for key in ccache_read_keys():
        result = subprocess.run(
            [
                's4cmd',
                '--endpoint-url', 'https://s3.cfdata.org',
                'ls', 's3://clickhouse-builds-ccache/v1/' + str_b64e(key)
            ],
            check=True,
            stdout=subprocess.PIPE)

        if len(result.stdout) != 0:
            good_key = key

    if not good_key:
        print("no good key found, done")
        return

    print('downloading ccache archive for key: ' + good_key)

    subprocess.run([
        's4cmd',
        '--endpoint-url', 'https://s3.cfdata.org',
        'get', 's3://clickhouse-builds-ccache/v1/' + str_b64e(good_key),
               HOME + '/' + str_b64e(good_key)
    ], check=True)

    subprocess.run([
        'tar',
        '-C', HOME + '/.ccache',
        '-xzf', HOME + '/' + str_b64e(good_key),
    ], check=True)

    # Remove initial archive to save disk.
    os.remove(HOME + '/' + str_b64e(good_key))


def upload_ccache():
    subprocess.run([
        'tar',
        '-C', HOME + "/.ccache",
        '-czf', HOME + "/ccache_output.tar.gz",
        '.'
    ], check=True)

    print('uploading cache for keys: ', ccache_write_keys())
    for key in ccache_write_keys():
        subprocess.run([
            's4cmd',
            '--endpoint-url', 'https://s3.cfdata.org',
            # Everyone can read so that you can use ccache locally if you have the bandwidth.
            # Ideally: download it manually and unarchive over your own ccache which you mount inside cfsetup with --ccache flag.
            '--API-GrantRead', 'uri=http://acs.amazonaws.com/groups/global/AllUsers',
            'put', '--force', HOME + "/ccache_output.tar.gz",
                              's3://clickhouse-builds-ccache/v1/' + str_b64e(key)
        ], check=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("op")

    args = p.parse_args()
    setup_env()

    if args.op == "download":
        download_ccache()
    elif args.op == "upload":
        upload_ccache()
    else:
        raise Exception("unexpected op: {}".format(args.op))


if __name__ == '__main__':
    main()
