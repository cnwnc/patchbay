defmodule PatchbayWeb.ConsoleSelectionHookJsTest do
  @moduledoc """
  Unit coverage for the `PatchbaySelection` hook that ships inline in
  `PatchbayWeb.Layouts`.

  The hook is mounted once on the application wrapper and listens on the
  document for focus, selection, and `phx:update` events, so every composer,
  source, structured, and prompt input is covered without per-input markup.
  The DOM in this harness is faked; LiveView patches are represented by
  resetting an input's selection and dispatching `phx:update`.

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
    const start = layoutHtml.indexOf('const PatchbaySelection')
    const stop = layoutHtml.indexOf('const PatchbayDetails')
    assert(start > 0 && stop > start, 'layout contains the PatchbaySelection hook')

    const literalStart = layoutHtml.indexOf('{', start)
    const literal = layoutHtml.slice(literalStart, stop).trim()
    assert(literal.endsWith('}'), 'hook source is an object literal')
    return literal
  }

  const listeners = {}
  const elements = []
  let activeElement = null

  const document = {
    body: {tagName: 'BODY'},
    activeElement,
    addEventListener(type, handler) {
      ;(listeners[type] = listeners[type] || []).push(handler)
    },
    removeEventListener(type, handler) {
      listeners[type] = (listeners[type] || []).filter((fn) => fn !== handler)
    },
    dispatch(type, event) {
      for (const handler of listeners[type] || []) handler(event)
    },
    querySelectorAll(selector) {
      assert(selector === 'input, textarea', 'default selector is input, textarea')
      return elements.slice()
    },
    getElementById(id) {
      return elements.find((el) => el.id === id) || null
    }
  }

  Object.defineProperty(document, 'activeElement', {
    get() {
      return activeElement || document.body
    }
  })

  function makeInput(attrs, value) {
    const el = {
      tagName: attrs.tagName || 'INPUT',
      type: attrs.type || 'text',
      id: attrs.id || '',
      disabled: false,
      readOnly: false,
      isConnected: true,
      value,
      selectionStart: 0,
      selectionEnd: 0,
      selectionDirection: 'none',
      getAttribute(name) {
        if (name === 'name') return attrs.name || null
        if (name === 'type') return attrs.type || null
        return null
      },
      focus() {
        activeElement = el
      },
      setSelectionRange(start, end, direction) {
        el.selectionStart = start
        el.selectionEnd = end
        el.selectionDirection = direction || 'none'
      }
    }

    elements.push(el)
    return el
  }

  const layoutHtml = fs.readFileSync(process.env['PATCHBAY_LAYOUT'], 'utf8')
  const hook = Object.assign({}, eval('(' + extractHookSource(layoutHtml) + ')'))
  hook.el = {}
  hook.mounted()

  const composer = makeInput({name: 'message[content]'}, 'hello world')
  const prompt = makeInput({tagName: 'TEXTAREA', name: 'source'}, 'line one\nline two')

  // Focus and select inside the composer.
  activeElement = composer
  composer.selectionStart = 2
  composer.selectionEnd = 7
  composer.selectionDirection = 'backward'
  document.dispatch('focusin', {target: composer})

  // The next LiveView patch rewrites the value and resets the caret.
  composer.selectionStart = composer.value.length
  composer.selectionEnd = composer.value.length
  composer.selectionDirection = 'none'
  document.dispatch('phx:update', {})

  assert(composer.selectionStart === 2, 'start is restored after a patch')
  assert(composer.selectionEnd === 7, 'end is restored after a patch')
  assert(composer.selectionDirection === 'backward', 'direction is restored after a patch')

  // Textareas keep their selection too (LiveView skips a non-INPUT range).
  activeElement = prompt
  prompt.selectionStart = 6
  prompt.selectionEnd = 3
  prompt.selectionDirection = 'backward'
  document.dispatch('selectionchange', {})
  prompt.selectionStart = prompt.value.length
  prompt.selectionEnd = prompt.value.length
  document.dispatch('phx:update', {})

  assert(prompt.selectionStart === 6, 'textarea start is restored')
  assert(prompt.selectionEnd === 3, 'textarea end is restored')
  assert(prompt.selectionDirection === 'backward', 'textarea direction is restored')

  // A patch caused by typing in another field does not steal focus.
  const other = makeInput({id: 'structured-name', name: 'structured[name]'}, 'researcher')
  activeElement = other
  other.selectionStart = 4
  other.selectionEnd = 4
  document.dispatch('focusin', {target: other})
  document.dispatch('phx:update', {})

  assert(activeElement === other, 'an unrelated focused input keeps focus')

  // Blurring before a patch avoids re-focusing the old input.
  activeElement = document.body
  document.dispatch('focusout', {target: other})
  document.dispatch('phx:update', {})

  assert(activeElement === document.body, 'a blurred input is not refocused')

  hook.destroyed()
  assert((listeners['phx:update'] || []).length === 0, 'destroyed removes the update listener')
  assert((listeners['selectionchange'] || []).length === 0, 'destroyed removes selection listeners')

  console.log('HOOK OK')
  """

  test "PatchbaySelection preserves active input and textarea selections across patches" do
    conn =
      PatchbayWeb.AuthTestHelper.authenticated_conn()
      |> get("/")

    html = html_response(conn, 200)

    assert html =~ ~s(phx-hook="PatchbaySelection")
    assert html =~ "const PatchbaySelection"

    node = System.find_executable("node")

    if is_nil(node) do
      IO.warn("node is not available; skipping the PatchbaySelection hook unit test")
    else
      root_dir =
        Path.join(System.tmp_dir!(), "patchbay-selection-#{System.unique_integer([:positive])}")

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
