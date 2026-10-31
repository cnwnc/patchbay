defmodule PatchbayWeb.ConsoleStreamHookJsTest do
  @moduledoc """
  Unit coverage for the `PatchbayStream` autoscroll hook that ships inline in
  `PatchbayWeb.Layouts`.

  The hook source is extracted from the real root layout so the test exercises
  the exact code the browser runs. The DOM (`{passive: true}` options,
  `ResizeObserver`, `requestAnimationFrame`, scroll geometry) is faked in a
  harness and the hook is driven through its real LiveView lifecycle
  callbacks:

    * mounted pins and follows the bottom.
    * while pinned, `updated()` (rAF) and ResizeObserver callbacks re-follow
      after content or height changes.
    * user scrolling away from the bottom unpins; later patches and row
      resizes no longer force the scroll position.
    * scrolling back to the bottom edge repins.
    * a `data-stream-agent` change (agent switch) re-pins to the bottom even
      if the previous agent had been scrolled up.

  Requires a `node` executable; skips with a warning otherwise.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint PatchbayWeb.Endpoint

  @harness ~S"""
  'use strict'
  const fs = require('fs')

  function assert(condition, message) {
    if (!condition) {
      console.error('FAILED: ' + message)
      process.exit(1)
    }
  }

  function extractHookSource(layoutHtml) {
    const start = layoutHtml.indexOf('const PatchbayStream')
    const stop = layoutHtml.indexOf('const PatchbaySelection')
    assert(start > 0 && stop > start, 'layout contains the PatchbayStream hook')

    const literalStart = layoutHtml.indexOf('{', start)
    const literal = layoutHtml.slice(literalStart, stop).trim()
    assert(literal.endsWith('}'), 'hook source is an object literal')
    return literal
  }

  const pendingFrames = []
  const window = {
    requestAnimationFrame(callback) {
      pendingFrames.push(callback)
    }
  }

  const observers = []
  class ResizeObserver {
    constructor(callback) {
      this.callback = callback
      this.targets = new Set()
      observers.push(this)
    }
    observe(target) {
      this.targets.add(target)
    }
    disconnect() {
      this.disconnected = true
      this.targets.clear()
    }
    fire() {
      this.callback()
    }
  }

  function makeList() {
    const list = {
      rows: [],
      listeners: {},
      dataset: {streamAgent: 'researcher'},
      scrollHeight: 0,
      clientHeight: 400,
      addEventListener(type, handler) {
        ;(this.listeners[type] = this.listeners[type] || []).push(handler)
      },
      removeEventListener(type, handler) {
        this.listeners[type] = (this.listeners[type] || []).filter((fn) => fn !== handler)
      },
      dispatch(type, event) {
        for (const handler of this.listeners[type] || []) handler(event)
      },
      appendRow() {
        const row = {id: 'row-' + this.rows.length}
        this.rows.push(row)
        return row
      },
      querySelectorAll(selector) {
        assert(selector === ':scope > li', 'only observes direct list rows')
        const rows = this.rows
        return {
          forEach(consumer) {
            for (const row of rows) consumer(row)
          }
        }
      },
      maxHeight() {
        return this.scrollHeight - this.clientHeight
      }
    }

    let scrollTop = 0
    Object.defineProperty(list, 'scrollTop', {
      get() {
        return scrollTop
      },
      set(value) {
        scrollTop = Math.max(0, Math.min(value, list.scrollHeight - list.clientHeight))
      }
    })

    return list
  }

  const layoutHtml = fs.readFileSync(process.env['PATCHBAY_LAYOUT'], 'utf8')
  const hook = Object.assign({}, eval('(' + extractHookSource(layoutHtml) + ')'))
  const list = makeList()

  function flushFrames() {
    while (pendingFrames.length > 0) pendingFrames.shift()()
  }

  function patch(newScrollHeight) {
    list.scrollHeight = newScrollHeight
    hook.updated()
    flushFrames()
  }

  function resizeRows() {
    const observer = observers.find((entry) => entry.targets.has(list))
    assert(observer, 'list is observed by a ResizeObserver')

    for (const row of list.rows) {
      assert(observer.targets.has(row), 'every row is observed by a ResizeObserver')
    }

    observer.fire()
  }

  function userScrollsTo(offset) {
    list.scrollTop = offset
    list.dispatch('scroll', {})
  }

  list.rows.push(...[{id: 'row-0'}, {id: 'row-1'}])
  list.scrollHeight = 1400
  hook.el = list
  hook.mounted()
  flushFrames()

  assert(hook.pinned === true, 'mounted starts pinned')
  assert(list.scrollTop === list.maxHeight(), 'mounted scrolls to the bottom')

  // Frequent LiveView patches while pinned keep the list at the bottom.
  patch(1600)
  assert(list.scrollTop === list.maxHeight(), 'patch while pinned keeps bottom')

  // Details expanding above layout only: ResizeObserver fires after layout.
  list.scrollHeight = 1800
  resizeRows()
  assert(list.scrollTop === list.maxHeight(), 'row resize while pinned keeps bottom')

  // Scrolling up unpins and later patches leave the scroll alone.
  userScrollsTo(300)
  assert(hook.pinned === false, 'scrolling up unpins')

  patch(2100)
  assert(list.scrollTop === 300, 'patch while unpinned does not force scroll')
  assert(hook.pinned === false, 'patch while unpinned does not repin')

  // Details expansion while unpinned must not yank the view down.
  list.scrollHeight = 2400
  resizeRows()
  assert(list.scrollTop === 300, 'row resize while unpinned does not force scroll')

  // Returning to the bottom edge repins and following resumes.
  userScrollsTo(0)
  list.scrollHeight = 2400
  userScrollsTo(list.maxHeight())
  assert(hook.pinned === true, 'returning to the bottom repins')

  patch(2700)
  assert(list.scrollTop === list.maxHeight(), 'patch after repin keeps bottom')

  // Scrolling up again, then switching agents re-pins to the bottom.
  userScrollsTo(120)
  assert(hook.pinned === false, 'scrolling up before agent switch unpins')
  list.rows.length = 0
  list.rows.push({id: 'row-0'})
  list.scrollHeight = 900
  list.dataset.streamAgent = 'worker'
  hook.updated()
  flushFrames()
  assert(hook.pinned === true, 'agent switch re-pins')
  assert(list.scrollTop === list.maxHeight(), 'agent switch scrolls to the bottom')

  // New rows after a patch get observed too.
  list.appendRow()
  hook.updated()
  flushFrames()
  resizeRows()

  // An upward wheel event unpins immediately, without waiting for the
  // resulting scroll event.
  userScrollsTo(list.maxHeight())
  assert(hook.pinned === true, 'bottom before wheel test')
  list.dispatch('wheel', {deltaY: -100})
  assert(hook.pinned === false, 'upward wheel unpins when the list can scroll up')
  list.dispatch('wheel', {deltaY: 100})
  assert(hook.pinned === false, 'downward wheel alone does not repin')
  userScrollsTo(list.maxHeight())

  // Tearing down disconnects.
  hook.destroyed()
  assert(observers.every((entry) => entry.disconnected), 'destroyed disconnects the ResizeObserver')
  assert(list.listeners['scroll'].length === 0, 'destroyed removes the scroll listener')
  assert(list.listeners['wheel'].length === 0, 'destroyed removes the wheel listener')

  console.log('HOOK OK')
  """

  test "PatchbayStream follows patches, unpins on user scroll and repins at the bottom" do
    conn =
      PatchbayWeb.AuthTestHelper.authenticated_conn()
      |> get("/")

    html = html_response(conn, 200)

    node = System.find_executable("node")

    if is_nil(node) do
      IO.warn("node is not available; skipping the PatchbayStream hook unit test")
    else
      root_dir =
        Path.join(System.tmp_dir!(), "patchbay-hook-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root_dir)
      harness_path = Path.join(root_dir, "harness.js")
      layout_path = Path.join(root_dir, "layout.html")

      File.write!(harness_path, @harness)
      File.write!(layout_path, html)

      try do
        {output, exit_status} =
          System.cmd(node, [harness_path], env: %{"PATCHBAY_LAYOUT" => layout_path})

        assert exit_status == 0
        assert output =~ "HOOK OK"
      after
        File.rm_rf!(root_dir)
      end
    end
  end
end
