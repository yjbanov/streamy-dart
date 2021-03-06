library streamy.runtime.transforms.test;

import 'package:unittest/unittest.dart';
import 'package:streamy/testing/testing.dart';
import 'package:streamy/streamy.dart';

main() {
  group('RequestTrackingTransformer', () {
    test('Properly tracks a request', () {
      var bareHandler = (testRequestHandler()
        ..values([
          new Response(new Entity()..['x'] = 'a', Source.RPC, 0),
          new Response(new Entity()..['x'] = 'b', Source.RPC, 0)]))
        .build();
      var handler = bareHandler.transform(() => new UserCallbackTracingTransformer());
      var tracer = new StreamTracer(UserCallbackTracingTransformer.traceDonePredicate);
      var root = new TestingRoot(handler, tracer);

      var x = ' ';
      var callCount = 0;
      tracer.requests.listen(expectAsync1((traced) {
        expect(traced.request, equals(TEST_GET_REQUEST));
        expect(x, equals(' '));
        x = '_';
        traced.events.where((event) => event is UserCallbackQueuedEvent).listen(expectAsync1((_) {
          if (callCount == 0) {
            expect(x, equals('_'));
          } else {
            expect(x, equals('a'));
          }
        }, count: 2));
        traced.events.where((event) => event is UserCallbackDoneEvent).listen(expectAsync1((_) {
          if (callCount == 1) {
            expect(x, equals('a'));
          } else {
            expect(x, equals('b'));
          }
        }, count: 2));
        traced.events.last.then(expectAsync1((lastEvent) {
          expect(lastEvent.runtimeType, RequestOverEvent);
        }));
      }));
      root.send(TEST_GET_REQUEST).listen(expectAsync1((response) {
        x = response.entity['x'];
        callCount++;
      }, count: 2));
    });
    test('Properly handles errors', () {
      var bareHandler = (testRequestHandler()
        ..error(new ArgumentError("test")))
        .build();
      var handler = bareHandler.transform(() => new UserCallbackTracingTransformer());
      var tracer = new StreamTracer(UserCallbackTracingTransformer.traceDonePredicate);
      var root = new TestingRoot(handler, tracer);
      var sawErrorOnStream = false;

      tracer.requests.listen(expectAsync1((traced) {
        expect(traced.request, equals(TEST_GET_REQUEST));
        traced.events.where((event) => event is UserCallbackQueuedEvent).listen(expectAsync1((_) {
          expect(sawErrorOnStream, isFalse);
        }));
        traced.events.where((event) => event is UserCallbackDoneEvent).listen(expectAsync1((_) {
          expect(sawErrorOnStream, isTrue);
        }));
        traced.events.last.then(expectAsync1((lastEvent) {
          expect(lastEvent.runtimeType, RequestOverEvent);
        }));
      }));
      root.send(TEST_GET_REQUEST).listen(expectAsync1((_) {}, count: 0))
        .onError(expectAsync1((error) {
          expect(error, new isInstanceOf<ArgumentError>());
          sawErrorOnStream = true;
        }));
    });
  });
}