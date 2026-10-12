"""Inspect the actual self-extracting delivery file and all five Docker archives."""
import argparse
import json
import pathlib
import tarfile
import tempfile
import shutil


def verify(path, arch, version, bom):
    expected = {f"images/{row['name']}-{arch}.tar": row for row in bom}
    checked = set()
    metadata = {}
    with open(path, 'rb') as source:
        for line in source:
            if line == b'__ARCHINFRA_PAYLOAD_BELOW__\n':
                break
        else:
            raise ValueError('Missing payload marker')
        with tarfile.open(fileobj=source, mode='r|gz') as payload:
            for member in payload:
                name = member.name.removeprefix('./')
                if name in ('ARCH', 'VERSION', 'images/index.tsv', 'charts/elasticsearch/Chart.yaml'):
                    metadata[name] = payload.extractfile(member).read().decode().strip()
                if name not in expected:
                    continue
                if name in checked:
                    raise ValueError(f'Duplicate image: {name}')
                row = expected[name]
                with tempfile.TemporaryFile() as saved:
                    shutil.copyfileobj(payload.extractfile(member), saved)
                    saved.seek(0)
                    with tarfile.open(fileobj=saved) as image:
                        manifest = json.load(image.extractfile('manifest.json'))
                        assert len(manifest) == 1, f'{name}: expected one image'
                        entry = manifest[0]
                        ref = f"archinfra-payload/{row['name']}:{version}-{arch}"
                        assert entry['RepoTags'] == [ref], f'{name}: incorrect tag'
                        config = json.load(image.extractfile(entry['Config']))
                        assert (config['os'], config['architecture']) == ('linux', arch), f'{name}: wrong platform'
                        assert entry['Layers'], f'{name}: no image layers'
                        for layer in entry['Layers']:
                            assert image.getmember(layer).size > 0, f'{name}: missing/empty layer'
                checked.add(name)
                print(f'PASS: {name} platform, tag and layers')
    assert checked == set(expected), 'Incomplete image payload'
    assert metadata['ARCH'] == arch, 'Incorrect package architecture'
    assert metadata['VERSION'] == version, 'Incorrect package version'
    assert metadata['charts/elasticsearch/Chart.yaml'], 'Missing chart'
    expected_index = {
        f"{row['name']}-{arch}.tar\tarchinfra-payload/{row['name']}:{version}-{arch}\t{row['target']}"
        for row in bom
    }
    lines = metadata['images/index.tsv'].splitlines()
    assert len(lines) == len(expected_index) and set(lines) == expected_index, 'Incorrect offline image index'
    print(f'PASS: complete {version}/{arch} offline installer')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('installer', type=pathlib.Path)
    parser.add_argument('--arch', required=True, choices=['amd64', 'arm64'])
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    verify(args.installer, args.arch, (root / 'VERSION').read_text().strip(),
           json.loads((root / 'images/image.json').read_text()))
