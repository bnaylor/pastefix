# Pastefix

> This is an archival commit of the old ~2007 code prior to restarting development
> on it in 2019..  Just for posterity.  Apparently I don't even have the code for
> the most recent version.  All the stuff in the TODO file actually got done, like
> sparkle updates and so on.  Oh well.  It's so old XCode barfs on it anyway, so
> I think I'll be starting over from scratch!
>
> The most recent old version (0.9.3, binary) is [still available](http://scromp.net/Pastefix/)

## Initial readme text taken from old web page


### General Use

Pastefix is a brutish little utility that strips or converts non-ASCII
characters out of UTF-8 and other fancy encodings in text selections from your
clipboard so they can be pasted into old-school venues such as IRC. It has a
few other IRC-related convenience functions, but primarily it is meant simply
to clean up text pastes from heavily-formatted web pages, which can often cause
problems for other users. Pastefix is also handy for easily stripping out text
styling for pasting in normal applications - fonts, colors, italics, etc. will
all be removed.

As an application, the behavior of Pastefix is somewhat strange -- it tries to
stay out of your way as much as possible and perform everything it can
automatically, so it bends some of the general Apple user interface
conventions.

Normally it remains hidden, and you never see it until you want to clean up a
chunk of text. You then bring Pastefix into focus by clicking on the Dock icon,
using Alt-tab, or best of all, the global hotkey (which defaults to
Command-Shift-c.) When you bring Pastefix into focus, it automatically copies
and converts the contents of your clipboard and previews it for you. In most
cases, this is all that needs to be done. You can simply press 'Save to
Clipboard' (or Command-s) and Pastefix updates your clipboard with the
sanitized text and disappears again. You can then safely paste.

So, the default "workflow" would look something like:

- Decide to paste text from some application into 7-bit environment
- Highlight text
- Command-c to copy
- Command-Shift-c to switch to Pastefix
- Command-s to save to clipboard
- Switch to destination application
- Command-v to paste

### Optional Action Buttons

**Split**: If any of the lines in your text selection are longer than a
configurable maximum, the 'Split' button activates. Pressing that button will
break the too-long lines into shorter chunks. This is meant to help you prevent
your pastes from being cut off by the nebulous IRC maximum line length
limitation, which IRC clients are notoriously bad about calculating.

**Refresh**: If you edit the text in Pastefix, the 'Refresh' button will
activate. This button will re-copy the clipboard text should you choose to
discard your edits. If you switch away from Pastefix without saving your edits
and come back later, it will still contain the edited text. If you want to
discard that and load new clipboard contents, press Refresh.  Preferences

**Autohide**: This setting controls whether Pastefix automatically hides itself
when it loses focus.

**Check for Updates**: Pastefix can automatically check for updated versions and
download them for you. To disable that behavior, uncheck this setting.

**Use Iconv library for transliterations**: By default, Pastefix uses the GNU
iconv library to attempt to gracefully transliterate strange characters into
reasonable ASCII equivalents. If you disable this option, it will be
considerably more aggressive in downsampling text. For example, 'é' will simply
become 'e', and most web dingbats will be stripped entirely.

**Maximum line length**: This is the setting that controls when Pastefix thinks a
line is too long to paste into IRC. This number is based on the general IRC
maximum message buffer length, subtracting: 2 x average nick length, a few
characters of protocol overhead, a general guess as to the average target name
length, and an even wilder guess about average hostname length. You may need to
tweak this setting if any of those values deviate for you. Do be aware that
this real limit will still vary somewhat based on the name of the entity to
which you are sending your messages, so it is best to err on the side of
caution.

**Activation hotkey**: This is the keystroke registered globally that causes
Pastefix to steal focus. It defaults to Command-Shift-c because that seems
pretty convenient to hit right after copying some text, but you can set it to
whatever you want.


