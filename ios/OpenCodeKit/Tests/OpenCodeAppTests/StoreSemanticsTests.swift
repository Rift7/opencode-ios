import ComposableArchitecture
import Foundation
import Testing

// Representative compositions over the maintained TCA store. These are migration gates for the
// semantics the Kotlin store relies on; they do not test TCA itself.

@Reducer
private struct OrderedComposition {
  @ObservableState
  struct State: Equatable {
    var steps: [String] = []
    var marks: [Int] = []
  }

  enum Action: Equatable {
    case run
    case mark(Int)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      guard case .run = action else { return .none }
      state.steps.append("first")
      return .none
    }
    Reduce { state, action in
      guard case .run = action else { return .none }
      state.steps.append("second-\(state.steps.count)")
      return .none
    }
    Reduce { state, action in
      switch action {
      case .run:
        state.steps.append("third")
        return .concatenate(.send(.mark(1)), .send(.mark(2)), .send(.mark(3)))
      case .mark(let value):
        state.marks.append(value)
        return .none
      }
    }
  }
}

@MainActor
@Suite("Store semantics")
struct StoreSemanticsTests {
  @Test("sibling reducers run in declaration order over one action")
  func siblingOrdering() async {
    let store = TestStore(initialState: OrderedComposition.State()) {
      OrderedComposition()
    }

    await store.send(.run) {
      $0.steps = ["first", "second-1", "third"]
    }
    for mark in 1...3 {
      await store.receive(.mark(mark)) {
        $0.marks.append(mark)
      }
    }
  }
}

@Reducer
private struct Worker {
  @ObservableState
  struct State: Equatable {
    var ticks: [String] = []
  }

  enum Action: Equatable {
    case start(String)
    case cancel(String)
    case tick(String)
  }

  @Dependency(\.continuousClock) private var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .start(let id):
        let clock = clock
        return .run { send in
          for await _ in clock.timer(interval: .seconds(1)) {
            await send(.tick(id))
          }
        }
        .cancellable(id: id, cancelInFlight: true)

      case .cancel(let id):
        return .cancel(id: id)

      case .tick(let id):
        state.ticks.append(id)
        return .none
      }
    }
  }
}

@MainActor
@Suite("Cancellation identity")
struct CancellationIdentityTests {
  @Test("cancelling one identity leaves the other running")
  func identitiesAreIndependent() async {
    let clock = TestClock()
    let store = TestStore(initialState: Worker.State()) {
      Worker()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(.start("a"))
    await clock.advance(by: .seconds(1))
    await store.receive(.tick("a")) {
      $0.ticks.append("a")
    }

    await store.send(.start("b"))
    await store.send(.cancel("a"))
    await clock.advance(by: .seconds(1))
    await store.receive(.tick("b")) {
      $0.ticks.append("b")
    }

    await store.send(.cancel("b"))
    await store.finish()
  }

  @Test("restarting the same identity cancels the effect already in flight")
  func cancelInFlightIsPerIdentity() async {
    let clock = TestClock()
    let store = TestStore(initialState: Worker.State()) {
      Worker()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(.start("a"))
    await clock.advance(by: .seconds(1))
    await store.receive(.tick("a")) {
      $0.ticks.append("a")
    }

    await store.send(.start("a"))
    await clock.advance(by: .seconds(1))
    await store.receive(.tick("a")) {
      $0.ticks.append("a")
    }

    await store.send(.cancel("a"))
    await store.finish()
  }
}

@Reducer
private struct Editor {
  @ObservableState
  struct State: Equatable {
    var value = 0
  }

  enum Action: Equatable {
    case bump
  }

  var body: some Reducer<State, Action> {
    Reduce { state, _ in
      state.value += 1
      return .none
    }
  }
}

@Reducer
private struct HostWithChild {
  @ObservableState
  struct State: Equatable {
    var editor: Editor.State? = Editor.State()
    var observed: [Int] = []
  }

  enum Action: Equatable {
    case editor(Editor.Action)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, _ in
      state.observed.append(state.editor?.value ?? -1)
      return .none
    }
    .ifLet(\.editor, action: \.editor) {
      Editor()
    }
  }
}

@MainActor
@Suite("Child-first ifLet")
struct ChildFirstIfLetTests {
  @Test("the child reduces before the parent observes the same action")
  func childRunsFirst() async {
    let store = TestStore(initialState: HostWithChild.State()) {
      HostWithChild()
    }

    await store.send(.editor(.bump)) {
      $0.editor = Editor.State(value: 1)
      $0.observed = [1]
    }

    #expect(store.state.observed == [1])
  }
}

@Reducer
private struct Sheet {
  @ObservableState
  struct State: Equatable, Identifiable {
    let id: Int
    var ticks = 0

    init(id: Int = 1) {
      self.id = id
    }
  }

  enum Action: Equatable {
    case start
    case tick
  }

  @Dependency(\.continuousClock) private var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .start:
        let clock = clock
        return .run { send in
          for await _ in clock.timer(interval: .seconds(1)) {
            await send(.tick)
          }
        }
        .cancellable(id: "sheet-timer")

      case .tick:
        state.ticks += 1
        return .none
      }
    }
  }
}

@Reducer
private struct Shelf {
  @ObservableState
  struct State: Equatable {
    @Presents var sheet: Sheet.State?
  }

  enum Action: Equatable {
    case open
    case replace
    case sheet(PresentationAction<Sheet.Action>)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .open:
        state.sheet = Sheet.State()
      case .replace:
        if let current = state.sheet {
          state.sheet = Sheet.State(id: current.id + 1)
        }
      case .sheet(.dismiss):
        state.sheet = nil
      case .sheet:
        break
      }
      return .none
    }
    .ifLet(\.$sheet, action: \.sheet) {
      Sheet()
    }
  }
}

@MainActor
@Suite("Presented child cancellation")
struct PresentedChildCancellationTests {
  private func makeStore(clock: TestClock<Duration>) -> TestStoreOf<Shelf> {
    TestStore(initialState: Shelf.State()) {
      Shelf()
    } withDependencies: {
      $0.continuousClock = clock
    }
  }

  @Test("dismissing a presented child cancels the effect it started")
  func dismissalCancelsChildEffects() async {
    let clock = TestClock()
    let store = makeStore(clock: clock)

    await store.send(.open) {
      $0.sheet = Sheet.State()
    }
    await store.send(.sheet(.presented(.start)))

    await clock.advance(by: .seconds(1))
    await store.receive(.sheet(.presented(.tick))) {
      $0.sheet?.ticks = 1
    }

    await store.send(.sheet(.dismiss)) {
      $0.sheet = nil
    }

    await clock.advance(by: .seconds(3))
    await store.finish()
  }

  @Test("replacing the presented child's identity cancels the effect it started")
  func identityChangeCancelsChildEffects() async {
    let clock = TestClock()
    let store = makeStore(clock: clock)

    await store.send(.open) {
      $0.sheet = Sheet.State()
    }
    await store.send(.sheet(.presented(.start)))

    await clock.advance(by: .seconds(1))
    await store.receive(.sheet(.presented(.tick))) {
      $0.sheet?.ticks = 1
    }

    await store.send(.replace) {
      $0.sheet = Sheet.State(id: 2)
    }

    await clock.advance(by: .seconds(3))
    await store.finish()
  }
}
