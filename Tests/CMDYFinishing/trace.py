"""Join synthetic input edits to immutable model colors and native presentation.

Never treats GPU completion as presentation or equates a ScreenCaptureKit frame
timestamp with a Metal drawable timestamp. Only the explicit synthetic marker
row is inspected; no arbitrary terminal text is recorded by the app trace.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import statistics


def analyze(directory):
    def read(name): return json.loads((directory / name).read_text())
    latency = read('latency.json')
    cleanup = read('fixture-stop.json')
    assert cleanup['complete'] and not cleanup['pendingPIDs']
    stopped = list(cleanup['finalRecords'].values())
    assert len(stopped) == 1
    fixture = 'vim' if stopped[0]['record'].get('fixture') == 'vim' else 'raw-marker'
    if fixture == 'vim':
        assert stopped[0]['record']['insertedCharacters'] == len(latency['samples'])
    else:
        assert stopped[0]['record']['markerMode'] == latency['markerMode'] == 'local-row'
        received = read('fixture/received.json')
        assert [item['sequence'] for item in received] == [item['sequence'] for item in latency['samples']]
    events = [json.loads(line.split('CMDY_FRAME_TRACE ', 1)[1])
        for line in (directory / 'app.log').read_text().splitlines() if 'CMDY_FRAME_TRACE ' in line]
    events.sort(key=lambda item: item['started'])
    by_name = collections.defaultdict(list)
    for event in events: by_name[event['event']].append(event)
    factor = latency['timebase']['numer'] / latency['timebase']['denom']
    def ms(ticks): return ticks * factor / 1e6
    def fields(event, **wanted): return all(event['fields'].get(k) == v for k, v in wanted.items())
    def first(name, **wanted): return next(item for item in by_name[name] if fields(item, **wanted))
    samples = []
    for external in latency['samples']:
        sequence = external['sequence']
        expected = ((48 + sequence % 16 * 11) << 16) | ((48 + sequence // 16 % 16 * 11) << 8) | 211
        # Vim paints the full status row; the raw responder paints only eight
        # central cells. Bind the actual generated color for that fixture.
        marker_fields = dict(input=sequence, middleRGB=expected)
        if fixture == 'vim': marker_fields.update(leftRGB=expected, rightRGB=expected)
        markers = [item for item in by_name['model.fixtureMarker'] if fields(item, **marker_fields)]
        assert markers, 'missing actual generated marker in immutable model'
        model = markers[0]['fields']['model']
        assert all(item['fields']['model'] == model for item in markers)
        write = first('model.inputWrite', input=sequence, model=model)
        surface = max((item for item in by_name['surface.input'] if fields(item, model=model)
            and external['postBeforeTicks'] <= item['started'] <= write['started']), key=lambda item: item['started'])
        candidates = []
        for marker in markers:
            generation = marker['fields']['generation']
            publication = first('model.renderPublication', input=sequence, model=model, generation=generation, accepted=1)
            native = first('worker.modelPublished', generation=generation)
            for presented in by_name['worker.framePresented']:
                if not fields(presented, generation=generation, surface=native['fields']['surface'], revision=native['fields']['revision']): continue
                stamp = presented['fields']['presentedNanoseconds']
                if stamp <= 0: continue
                identity = {name: presented['fields'][name] for name in ('surface', 'epoch', 'sequence', 'revision', 'generation')}
                submit = first('worker.frameSubmitted', **identity)
                service = first('worker.frameService', **identity)
                commit = first('draw.commit', frame=submit['fields']['frame'])
                gpu = first('draw.gpuComplete', frame=submit['fields']['frame'])
                assert marker['started'] <= publication['ended']
                assert native['started'] <= service['started'] <= commit['started']
                assert stamp >= commit['started'] * factor
                candidates.append((stamp, marker, publication, native, service, submit, commit, gpu, presented))
        assert candidates, 'no actual presented drawable carries the edit marker'
        stamp, marker, publication, native, service, submit, commit, gpu, presented = min(candidates, key=lambda item: item[0])
        feed = max((item for item in by_name['model.feed'] if fields(item, input=sequence, model=model)
            and item['ended'] <= marker['started']), key=lambda item: item['ended'])
        capture = first('model.capture', input=sequence, model=model, renderGeneration=marker['fields']['generation'])
        scoped = [item for item in events if surface['started'] <= item['started'] <= stamp / factor]
        samples.append(dict(sequence=sequence, expectedRGB=expected, model=model,
            identity=presented['fields'], frame=submit['fields']['frame'],
            stagesMilliseconds=dict(
                eventToApp=ms(surface['started'] - external['postBeforeTicks']),
                appToPTYWrite=ms(write['ended'] - surface['started']),
                PTYWriteToOutput=ms(feed['started'] - write['ended']),
                parse=ms(feed['durationTicks']), capture=ms(capture['durationTicks']),
                publicationToWorker=ms(service['started'] - publication['ended']),
                workerToCommit=ms(commit['ended'] - service['started']),
                GPU=gpu['fields']['gpuNanoseconds'] / 1e6,
                commitToPresentation=(stamp - commit['ended'] * factor) / 1e6,
                eventToNativePresentation=(stamp - external['postBeforeTicks'] * factor) / 1e6,
                eventToObservedMarker=external['eventToFrameMs']),
            hostCaptures=sum(item['event'] == 'capture.total' for item in scoped),
            hostRowRebuilds=sum(item['event'] in ('shaper.line', 'shaper.emptyLine') for item in scoped),
            externalFrame=external['frame'],
            traceEvents={item['event']: item for item in (surface, write, feed, capture, marker, publication, native, service, submit, commit, gpu, presented)}))
    assert all(sample['hostCaptures'] == 0 and sample['hostRowRebuilds'] == 0 for sample in samples)
    return dict(status='pass', fixture=fixture, samples=samples,
        medianMilliseconds={key: statistics.median(item['stagesMilliseconds'][key] for item in samples)
            for key in samples[0]['stagesMilliseconds']},
        inputSHA256={name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
            for name in ('app.log', 'latency.json', 'fixture-stop.json')},
        limitations=[
            'Diagnostic trace overhead; not admitted to before/after performance samples.',
            'First native presentation is selected by the edit color in an immutable model generation and actual presented time.',
            'External capture independently observes the same marker; its compositor clock does not identify a unique Metal drawable.',
            'ScreenCaptureKit display timestamps can precede Metal presentedTime; these are reported separately, never subtracted as a pipeline stage.',
            'Synthetic key and generated fixture marker, not physical keyboard-to-photon or total main-thread CPU.',
            'The explicit diagnostic marker projects one model row; ordinary production tracing does not.'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True); parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = analyze(args.input)
    with args.output.open('x') as stream: json.dump(result, stream, indent=2, sort_keys=True)
    print(json.dumps(dict(status=result['status'], samples=len(result['samples']), medianMilliseconds=result['medianMilliseconds']), indent=2))
