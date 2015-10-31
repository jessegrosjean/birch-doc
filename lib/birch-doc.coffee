{CompositeDisposable} = require 'atom'

module.exports = AtomDoc =
  subscriptions: null

  activate: (state) ->
    @subscriptions = new CompositeDisposable
    @subscriptions.add atom.commands.add 'atom-workspace', 'birch-doc:render-birch-doc': ->
      require('./renderer').renderDocs null, null,
        layout: 'class'

  deactivate: ->
    @subscriptions.dispose()
