let s:Buffer  = vital#esearch#import('Vim.Buffer')
let s:Log = esearch#log#import()
let s:Prelude = vital#esearch#import('Prelude')
let s:List    = vital#esearch#import('Data.List')
let [s:true, s:false, s:null, s:t_dict, s:t_float, s:t_func,
     \ s:t_list, s:t_number, s:t_string] = esearch#polyfill#definitions()

let g:esearch#preview#close_on = [
      \ 'QuitPre',
      \ 'BufEnter',
      \ 'BufWinEnter',
      \ 'TabLeave',
      \]
let g:esearch#preview#reset_on = 'BufWinLeave,BufLeave'
" The constant is used to ignore events used by :edit and :view commands to
" reduce the execution of unwanted autocommands like updating lightline,
" powerline etc.
" From docs: BufDelte - ...also used just before a buffer in the buffer list is
" renamed.
let g:esearch#preview#silent_open_eventignore =
      \ 'BufLeave,BufWinLeave,BufEnter,BufWinEnter,WinEnter,BufDelete'

let g:esearch#preview#buffers = {}
let g:esearch#preview#win     = s:null
let g:esearch#preview#last    = {}

fu! esearch#preview#open(filename, line, ...) abort
  let opts = get(a:000, 0, {})

  if !filereadable(a:filename)
    return s:false
  endif

  let shape = s:Shape.new({
        \ 'width':     get(opts, 'width',  s:null),
        \ 'height':    get(opts, 'height', s:null),
        \ 'alignment': get(opts, 'align',  'cursor'),
        \ })

  let close_on  = copy(g:esearch#preview#close_on)
  let close_on += get(opts, 'close_on',  ['CursorMoved', 'CursorMovedI', 'InsertEnter'])
  let close_on  = uniq(copy(close_on))

  let location = {
        \ 'filename': a:filename,
        \ 'line':     a:line,
        \ }
  let win_vars = {'&foldenable': s:false}
  let win_vars['&winhighlight'] = 'Normal:esearchNormalFloat,SignColumn:esearchSignColumnFloat,LineNr:esearchLineNrFloat,CursorLineNr:esearchCursorLineNrFloat,CursorLine:esearchCursorLineFloat,Conceal:esearchConcealFloat'
  call extend(win_vars, get(opts, 'let!', {})) " TOOO coverage

  let enter = get(opts, 'enter', s:false)
  if has_key(opts, 'emphasis')
    let emphasis = opts.emphasis
  else
    let emphasis = [esearch#emphasis#sign(), esearch#emphasis#highlighted_line()]
  endif

  let g:esearch#preview#last = s:Preview
        \.new(location, shape, emphasis, win_vars, opts, close_on, enter)

  if enter
    return g:esearch#preview#last.open_and_enter()
  else
    return g:esearch#preview#last.open()
  endif
endfu

fu! esearch#preview#is_open() abort
  " window id becomes invalid on bwipeout
  return g:esearch#preview#win isnot# s:null
        \ && esearch#win#exists(g:esearch#preview#win.id)
endfu

fu! esearch#preview#reset() abort
  " Sometimes emphasis remains when using tabclose command. We need to try
  " cleaning it up no matter the window opened or not.
  if has_key(g:esearch#preview#last, 'win')
    call g:esearch#preview#last.win.unplace_emphasis()
  endif
  " If #close() is used on every listed event, it can cause a bug where previewed
  " buffer loose it's content on existing swaps, so this method is defined to handle this
  if esearch#preview#is_open()
    let guard = g:esearch#preview#win.guard
    if !empty(guard) | call guard.restore() | endif
  endif
endfu

fu! esearch#preview#close(...) abort
  if esearch#preview#is_open() && !s:Buffer.is_cmdwin()
    call esearch#preview#reset()
    call g:esearch#preview#win.close()
    let g:esearch#preview#win = s:null
  endif
endfu

"""""""""""""""""""""""""""""""""""""""

let s:Preview = {}

fu! s:Preview.new(location, shape, emphasis, win_vars, opts, close_on, enter) abort dict
  let instance = copy(self)
  let instance.location = a:location
  let instance.shape    = a:shape
  let instance.win_vars = a:win_vars
  let instance.opts     = a:opts
  let instance.close_on = a:close_on
  let instance.enter    = a:enter
  let instance.emphasis = a:emphasis
  return instance
endfu

fu! s:Preview.open() abort dict
  let current_win = esearch#win#stay()
  let self.buffer = s:RegularBuffer.fetch_or_create(
        \ self.location.filename, g:esearch#preview#buffers)

  try
    let g:esearch#preview#win = s:create_or_update_floating_window(
          \ self.buffer, self.location, self.shape, self.close_on)
    let self.win = g:esearch#preview#win
    call self.win.enter()
    if !self.buffer.edit()
      call self.buffer.view()
    endif

    " it's better to let variables after editing the buffer to prevent
    " inheriting some options by buffers (for example, &winhl local to window
    " becoms local to buffer).
    call self.win.let(self.win_vars)
    call self.win.place_emphasis(self.emphasis)
    call self.win.reshape()
    call self.win.init_leaved_autoclose_events()
  catch
    call esearch#preview#close()
    call s:Log.error(v:exception . (g:esearch#env is 0 ? '' : v:throwpoint))
    return s:false
  finally
    noau keepj call current_win.restore()
  endtry

  return s:true
endfu

fu! s:Preview.open_and_enter() abort dict
  let current_win = esearch#win#stay()
  let reuse_existing = s:false
  let self.buffer = s:RegularBuffer.new(self.location.filename, reuse_existing)

  try
    call esearch#preview#close()
    let g:esearch#preview#win = s:FloatingWindow
          \.new(self.buffer, self.location, self.shape, self.close_on)
          \.open()
    let self.win = g:esearch#preview#win
    call self.win.enter()
    if !self.buffer.edit_allowing_swap_prompt()
      call esearch#preview#close()
      return s:false
    endif

    " it's better to let variables after editing the buffer to prevent
    " inheriting some options by buffers (for example, &winhl local to window
    " becoms local to buffer).
    call self.win.let(self.win_vars)
    call self.win.place_emphasis(self.emphasis)
    call self.win.reshape()
    call self.win.init_entered_autoclose_events()
  catch
    call esearch#preview#close()
    call s:Log.error(v:exception)
    return s:false
  endtry

  return s:true
endfu

"""""""""""""""""""""""""""""""""""""""

let s:RegularBuffer = {'kind': 'regular', 'swapname': ''}

fu! s:RegularBuffer.new(filename, ...) abort dict
  let instance = copy(self)
  let instance.filename = a:filename

  let reuse_existing = get(a:000, 0, s:true)
  if reuse_existing && bufexists(a:filename)
    let instance.id = esearch#buf#find(a:filename)
    let instance.bufwinid = bufwinid(instance.id)
  else
    let instance.id = nvim_create_buf(1, 0)
    let instance.bufwinid = -1
  endif

  return instance
endfu

fu! s:RegularBuffer.fetch_or_create(filename, cache) abort dict
  if has_key(a:cache, a:filename)
    let instance = a:cache[a:filename]
    if instance.is_valid()
      return instance
    endif
    call remove(a:cache, a:filename)
  endif

  let instance = self.new(a:filename)
  let a:cache[a:filename] = instance

  return instance
endfu

fu! s:RegularBuffer.view() abort dict
  let eventignore = esearch#let#restorable({'&eventignore': g:esearch#preview#silent_open_eventignore})
  try
    exe 'keepj view ' . fnameescape(self.filename)
  finally
    call eventignore.restore()
  endtry
endfu

fu! s:RegularBuffer.edit_allowing_swap_prompt() abort dict
  if exists('#esearch_preview_autoclose')
    au! esearch_preview_autoclose
  endif

  try
    exe 'edit ' . fnameescape(self.filename)
  catch /E325:/ " swapexists exception, will be handled by a user
  catch /Vim:Interrupt/ " Throwed on cancelling swap
  endtry
  " When (Q)uit or (A)bort are pressed - vim unloads the current buffer as it
  " was with an existing swap
  if empty(bufname('%'))
    exe self.id . 'bwipeout'
    return s:false
  endif

  let current_buffer_id = bufnr('%')
  if current_buffer_id != self.id && bufexists(self.id)
    exe self.id . 'bwipeout'
  endif
  let self.id = current_buffer_id

  return s:true
endfu

fu! s:RegularBuffer.edit() abort dict
  if exists('#esearch_preview_autoclose')
    au! esearch_preview_autoclose
  endif

  " NOTE The conditions below are needed to reuse already existing buffers where
  " possible. It's important as existing and displayed buffers may contain
  " information valuable for navigation like signs, highlights etc. as well as
  " actual changes made by user in case the buffer is displayed and modified.
  "
  " Fallbacks are required as it's impossible to handle the swap prompt using
  " regular buffer and autocommand hooks to toggle it. The swap prompt should be
  " suppressed on displaying and appeared on entering.

  " If the buffer has a filename equal to the previewed filename
  if expand('%:p') ==# simplify(self.filename)
    let win_ids = win_findbuf(self.id)
    let is_hidden = empty(win_ids) || win_ids ==# [g:esearch#preview#win.id]

    if !is_hidden " if there're opened windows with this buffer attached
      return s:true " Reuse the buffer
    elseif filereadable(self.swapname) " OR if there's existing swap
      return s:false " Use the fallback
    endif
  endif
  " Otherwise - use :edit to verify that there's no swapfiles appeared and
  " also preload the highlights and other stuff

  let s:swapname = ''
  let eventignore = esearch#let#restorable({'&eventignore': g:esearch#preview#silent_open_eventignore})
  try
    aug esearch_preview_swap_probe
      au!
      au SwapExists * ++once let s:swapname = v:swapname | let v:swapchoice = 'q'
    aug END
    exe 'keepj edit ' . fnameescape(self.filename)
  finally
    call eventignore.restore()
    au! esearch_preview_swap_probe
  endtry
  let self.swapname = s:swapname

  if !empty(s:swapname)
    return s:false
  endif

  " if the buffer is already created, vim switches to it leaving an empty
  " buffer we have to cleanup
  let current_buffer_id = bufnr('%')
  if current_buffer_id != self.id && bufexists(self.id)
    exe self.id . 'bwipeout'
  endif
  let self.id = current_buffer_id

  aug esearch_prevew_make_regular
    au!
    au BufWinEnter,BufEnter <buffer> ++once call esearch#preview#reset()
  aug END

  return s:true
endfu

fu! s:RegularBuffer.is_valid() abort dict
  return self.id >= 0 && nvim_buf_is_valid(self.id)
endfu

" Maintain the window as a singleton.
fu! s:create_or_update_floating_window(buffer, location, shape, close_on) abort
  if esearch#preview#is_open()
    return g:esearch#preview#win
          \.update(a:buffer, a:location, a:shape, a:close_on)
  else
    call esearch#preview#close()
    return s:FloatingWindow
          \.new(a:buffer, a:location, a:shape, a:close_on)
          \.open()
  endif
endfu

let s:FloatingWindow = {'guard': s:null, 'id': s:null, 'emphasis': s:null, 'variables': s:null}

fu! s:FloatingWindow.new(buffer, location, shape, close_on) abort dict
  let instance = copy(self)

  let instance.buffer   = a:buffer
  let instance.location = a:location
  let instance.shape    = a:shape
  let instance.close_on = a:close_on
  let instance.emphasis = []

  return instance
endfu

fu! s:FloatingWindow.let(variables) abort dict
  let self.variables = a:variables
  let self.guard = esearch#win#let_restorable(self.id, a:variables)
endfu

fu! s:FloatingWindow.open() abort dict
  try
    let original_options = esearch#util#silence_swap_prompt()
    let self.id = nvim_open_win(self.buffer.id, 0, {
          \ 'width':     self.shape.width,
          \ 'height':    self.shape.height,
          \ 'focusable': s:false,
          \ 'anchor':    self.shape.anchor,
          \ 'row':       self.shape.row,
          \ 'col':       self.shape.col,
          \ 'relative':  'win',
          \})
  finally
    call original_options.restore()
  endtry

  return self
endfu

fu! s:FloatingWindow.close() abort dict
  call self.unplace_emphasis()
  call nvim_win_close(self.id, 1)
endfu

" Shape specified on create is only to prevent blinks.
" Actual shape settings are set there
fu! s:FloatingWindow.reshape() abort dict
  if !self.buffer.is_valid()
    call s:Log.error('Preview buffer was deleted')
    return esearch#preview#close()
  endif

  " Prevent showing more lines than the buffer has
  call self.shape.clip_height(nvim_buf_line_count(self.buffer.id))
  let height = self.shape.height
  let line   = self.location.line

  if nvim_get_current_win() !=# self.id
    let current_win = esearch#win#stay()
    call self.enter()
  endif

  " allow the window be smaller than winheight
  let winminheight = esearch#let#restorable({'&winminheight': 1})

  try
    call nvim_win_set_config(self.id, {
          \ 'width':     self.shape.width,
          \ 'height':    self.shape.height,
          \ 'anchor':    self.shape.anchor,
          \ 'relative':  'win',
          \ 'row':       self.shape.row,
          \ 'col':       self.shape.col,
          \ })

    " Prevent showing EndOfBuffer
    if line('$') < height
      noau keepj call winrestview({'topline': 1, 'lnum': line})
    elseif line('$') - line < height / 2
      " EMphasized line will be shown below the center as EndOfBuffer is near.
      let topline = line('$') - height + 1
      noau keepj call winrestview({'topline': topline, 'lnum': line})
    else
      " The only way to perfectly center is to use zz as we cannot calculate the
      " correct topline position due to wraps that occupy more than one screen
      " line
      noau keepj call winrestview({'lnum': line})
      norm! zz
    endif
  finally
    call winminheight.restore()
    if exists('current_win') | noau keepj call current_win.restore() | endif
  endtry
endfu

fu! s:FloatingWindow.init_entered_autoclose_events() abort dict
  aug esearch_preview_autoclose
    " Before leaving a window
    au WinLeave * ++once call g:esearch#preview#last.win.guard.new(nvim_get_current_win()).restore() | call esearch#preview#close()
    " After entering another window
    au WinEnter * ++once au! esearch_preview_autoclose
    " From :h local-options
    " When splitting a window, the local options are copied to the new window. Thus
    " right after the split the contents of the two windows look the same.
    au WinNew * ++once call g:esearch#preview#last.win.guard.new(nvim_get_current_win()).restore() | au! esearch_preview_autoclose

    " NOTE dc09e176. Prevents options inheritance when trying to delete the
    " buffer. Grep note id to locate the test case.
    au BufDelete * ++once call esearch#preview#close()

    au CmdwinEnter * call g:esearch#preview#last.win.guard.new(nvim_get_current_win()).restore()
  aug END
endfu

fu! s:FloatingWindow.init_leaved_autoclose_events() abort dict
  let autocommands = join(self.close_on, ',')

  aug esearch_preview_autoclose
    au!
    exe 'au ' . autocommands . ' * ++once call esearch#preview#close()'
    exe 'au ' . g:esearch#preview#reset_on . ' * ++once call esearch#preview#reset()'
    " Prevent options inheritance
    au TabNewEntered * ++once call g:esearch#preview#last.win.guard.new(nvim_get_current_win()).restore()

    " We cannot close the preview when entering cmdwin, so the only option is to
    " reinitialize the events.
    au CmdwinLeave * ++once call g:esearch#preview#win.init_leaved_autoclose_events()
  aug END
endfu

fu! s:FloatingWindow.place_emphasis(emphasis) abort dict
  let self.emphasis = []

  for e in a:emphasis
    call add(self.emphasis, e.new(self.id, self.location.line))
    call self.emphasis[-1].place()
  endfor
endfu

" Helps to prevent blinks
fu! s:FloatingWindow.update(buffer, location, shape, close_on) abort dict
  let self.buffer   = a:buffer
  let self.location = a:location
  let self.shape    = a:shape
  let self.close_on = a:close_on

  " NOTE ae2cf10d. Prevent local variables inheritance while updating the
  " preview window
  call self.guard.restore()
  call nvim_win_set_buf(self.id, a:buffer.id)
  let self.guard = esearch#win#let_restorable(self.id, self.variables)

  " Emphasis must be removed as it doesn't correspond to a:location anymore
  call self.unplace_emphasis()

  return self
endfu

fu! s:FloatingWindow.is_entered() abort dict
  return nvim_get_current_win() ==# self.id
endfu

fu! s:FloatingWindow.unplace_emphasis() abort dict
  if !empty(self.emphasis)
    call map(self.emphasis, 'v:val.unplace()')
    let self.emphasis = s:null
  endif
endfu

fu! s:FloatingWindow.enter() abort dict
  noau keepj call esearch#win#goto(self.id)
endfu

"""""""""""""""""""""""""""""""""""""""

let s:Shape = {}

fu! s:Shape.new(measures) abort dict
  let instance = copy(self)
  let instance.winline = winline()
  let instance.wincol  = wincol()
  let instance.alignment = a:measures.alignment
  let instance.relative_win_position = nvim_win_get_position(0)

  if &showtabline ==# 2 || &showtabline == 1 && tabpagenr('$') > 1
    let instance.tabline_height = 1
  else
    let instance.tabline_height = 0
  endif
  if &laststatus ==# 2 || &laststatus == 1 && winnr('$') > 1
    let instance.statusline_height = 0
  else
    let instance.statusline_height = 1
  endif
  let instance.winheight = winheight(0)
  let instance.winwidth = winwidth(0)
  let instance.top = instance.tabline_height
  let instance.bottom = instance.winheight + instance.tabline_height + instance.statusline_height
  let instance.editor_top = instance.tabline_height
  let instance.editor_bottom = &lines - instance.tabline_height - instance.statusline_height - 1

  let default_height = min([19, &lines / 2])
  if instance.alignment ==# 'cursor'
    call extend(instance, {'width': 120, 'height': default_height})
    let instance.relative = 0
  elseif s:List.has(['top', 'bottom'], instance.alignment)
    call extend(instance, {'width': 1.0, 'height': default_height})
    let instance.relative = 1
  elseif s:List.has(['left', 'right'], instance.alignment)
    call extend(instance, {'width': 0.5, 'height': 1.0})
    let instance.relative = 1
  else
    throw 'Unknown preview align'
  endif

  let width = a:measures.width
  if s:Prelude.is_numeric(width) && width > 0
    let instance.width = width
  endif
  let height = a:measures.height
  if s:Prelude.is_numeric(height) && height > 0
    let instance.height = height
  endif

  let instance.height = s:absolute_value(instance.height, instance.winheight)
  let instance.width = s:absolute_value(instance.width, instance.winwidth)
  call instance.realign()

  return instance
endfu

fu! s:absolute_value(value, interval) abort
  if type(a:value) ==# type(1.0)
    return float2nr(ceil(a:value * a:interval))
  elseif type(a:value) ==# type(1) && a:value > 0
    return a:value
  else
    throw 'Wrong type of value ' . a:value
  endif
endfu

fu! s:Shape.realign() abort dict
  if self.alignment ==# 'cursor'
    call self.align_to_cursor()
  elseif self.alignment ==# 'top'
    return self.align_to_top()
  elseif self.alignment ==# 'bottom'
    return self.align_to_bottom()
  elseif self.alignment ==# 'left'
    return self.align_to_left()
  elseif self.alignment ==# 'right'
    return self.align_to_right()
  else
    throw 'Unknown preview align'
  endif
endfu

fu! s:Shape.align_to_top() abort dict
  let self.col    = self.relative_win_position[1]
  let self.row    = self.top
  let self.anchor = 'NW'
endfu

fu! s:Shape.align_to_right() abort dict
  let self.col    = self.relative_win_position[1] + self.winwidth + 1
  let self.row    = self.top
  let self.anchor = 'NE'
endfu

fu! s:Shape.align_to_left() abort dict
  let self.col    = self.relative_win_position[1]
  let self.row    = self.top
  let self.anchor = 'NW'
endfu

fu! s:Shape.align_to_bottom() abort dict
  let self.row    = self.bottom
  let self.col    = self.relative_win_position[1]
  let self.anchor = 'SW'
endfu

fu! s:Shape.align_to_cursor() abort dict
  if &lines - self.height - 1 < self.winline
    " if there's no room - show above
    let self.row = max([self.winline - self.height, self.top])
  else
    let self.row = self.winline
  endif
  let self.col = max([5, self.wincol - 1]) + self.relative_win_position[1]

  let self.anchor = 'NW'
endfu

fu! s:Shape.clip_height(height_limit) abort dict
  " Left and right aligned previews are stretched
  if s:List.has(['left', 'right'], self.alignment) | return | endif

  let self.height = min([
        \ a:height_limit,
        \ self.height,
        \ self.editor_bottom - self.editor_top])

  call self.realign()
endfu