highlightjs = require 'highlight.js'
_ = require 'underscore-plus'
hamlc = require 'haml-coffee'
assert = require 'assert'
marked = require 'marked'
tello = require 'tello'
donna = require 'donna'
path = require 'path'
fs = require 'fs'

class Renderer

  constructor: ->
    @compiledTemplates = {}
    @initReferenceMap()

  ###
  Section: Render
  ###

  renderModules: (sourcePaths, outPath, options={}) ->
    assert(sourcePaths, 'requires sourcePaths param')
    assert(outPath, 'requires outPath param')
    if sourcePaths
      unless fs.existsSync(outPath)
        fs.mkdirSync(outPath)
      metadata = donna.generateMetadata(sourcePaths)
      digestedMetadata = tello.digest(metadata)
      @metadata = digestedMetadata
      @renderClassList(outPath, options)
      @renderClasses(outPath, options)

  renderClasses: (outPath, options) ->
    for name, clazz of @metadata.classes
      renderedClazz = @renderClass clazz, options
      fs.writeFileSync(path.join(outPath, "#{name}.md"), renderedClazz)

  renderClassList: (outPath) ->
    classes = []
    for name, clazz of @metadata.classes
      classes.push name
    classes.sort()

    renderedClassList = @renderTemplate 'class-list',
      classes: classes

    fs.writeFileSync(path.join(outPath, 'class-list.html'), renderedClassList)

  renderClass: (clazz, options) ->
    clazz.descriptionSection = @renderDescriptionSection(clazz)
    clazz.examplesSection = @renderExamplesSection(clazz, options)
    clazz.sections = @renderSections(clazz, options)
    clazz.layout = options.layout or 'default'
    clazz.classesPath = options.classesPath or ''
    content = @renderTemplate 'class', clazz
    content.replace(/\n\n/, '\n')

  renderDescriptionSection: (clazz) ->
    if clazz.description
      @renderTemplate 'description-section', clazz,
        resolve: ['description']
        markdown: ['description']

  renderExamplesSection: (object, options) ->
    return '' unless object.examples
    if options?.verbose
      console.log("  Examples")
    examples = (@renderExample(example) for example in object.examples).join('\n')
    @renderTemplate('examples', examples: examples)

  renderExample: (example) ->
    example.description = @renderMarkdown(example.description)
    example.raw = @renderReferences(example.raw)
    example.raw = @renderMarkdown(example.raw)
    @renderTemplate('example', example)

  renderSections: (clazz, options) ->
    sections = clazz.sections
    sections.unshift({name: null})
    (@renderSection(clazz, section, options) for section in sections).join('\n')

  renderSection: (clazz, section, options) ->
    if options?.verbose
      console.log("  Section: #{section.name}")
    section.classProperties = @renderProperties(clazz.classProperties, section.name, 'static', options)
    section.properties = @renderProperties(clazz.instanceProperties, section.name, 'instance', options)
    section.classMethods = @renderMethods(clazz.classMethods, section.name, 'static', options)
    section.methods = @renderMethods(clazz.instanceMethods, section.name, 'instance', options)
    section.description = @renderReferences(section.description)
    section.description = @renderMarkdown(section.description)

    if section.classProperties.length > 0 or section.properties.length > 0 or
       section.classMethods.length > 0 or section.methods.length > 0 or
       section.description.length > 0
      @renderTemplate('section', section)

  renderProperties: (properties, sectionName, type, options) ->
    props = _.filter properties, (prop) -> prop.sectionName is sectionName
    props = _.map props, (prop) => @renderProperty(prop, type, options)
    props.join('\n')

  renderProperty: (property, type, options) ->
    if options?.verbose
      console.log("    Property: #{property.name}")
    property.id = "#{type}-#{property.name}"
    property.type = type
    property.signature = "#{@renderSignifier(type)}#{property.name}"
    property.examples = @renderExamplesSection(property, options)
    @renderTemplate('property', property, resolve: ['description'], markdown: ['description'])

  renderMethods: (methods, sectionName, type, options) ->
    methods = _.filter methods, (method) -> method.sectionName is sectionName
    methods = _.map methods, (method) => @renderMethod(method, type, options)
    methods.join('\n')

  renderMethod: (method, type, options) ->
    if options?.verbose
      console.log("    Method: #{method.name}")
    method.id = "#{type}-#{method.name}"
    method.type = type
    method.signature = "#{@renderSignifier(type)}#{@renderSignature(method)}"
    method.examples = @renderExamplesSection(method, options)
    method.parameterBlock = if method.arguments then @renderParameterBlock(method) else ''
    method.returnValueBlock = if method.returnValues then @renderReturnValueBlock(method) else ''
    @renderTemplate('method', method, resolve: ['description'], markdown: ['description'])

  renderSignature: (method) ->
    parameters = if method.arguments then @renderParameters(method) else ''
    "#{method.name}(#{parameters})"

  renderSignifier: (type) ->
    if type is 'static' then '.' else '::'

  renderParameterBlock: (method) ->
    rows = (@renderParameterRow(parameter) for parameter in method.arguments)
    @renderTemplate('parameter-block-table', rows: rows.join('\n'))

  renderParameterRow: (parameter) ->
    parameter.description = @renderReferences(parameter.description)
    parameter.description = @renderMarkdown(parameter.description, noParagraph: true)
    parameter.children = if parameter.children then @renderParameterChildren(parameter.children) else ''
    @renderTemplate('parameter-block-row', parameter)

  renderParameterChildren: (children) ->
    children = (@renderParameterChild(child) for child in children).join('\n')
    @renderTemplate('parameter-children', children: children)

  renderParameterChild: (child) ->
    @renderTemplate(
      'parameter-child',
      child,
      markdown: ['description'],
      resolve: ['description'],
      noParagraph: ['description']
    )

  renderReturnValueBlock: (method) ->
    rows = (@renderReturnValueRow(returnValue) for returnValue in method.returnValues)
    @renderTemplate('return-value-block-table', rows: rows.join('\n'))

  renderReturnValueRow: (returnValue) ->
    returnValue.description = @renderReferences(returnValue.description)
    returnValue.description = @renderMarkdown(returnValue.description, noParagraph: true)
    @renderTemplate('return-value-block-row', returnValue)

  renderParameters: (method) ->
    formatArgument = (argument) ->
      opt = if argument.isOptional then '<sup>?</sup>' else ''
      "#{argument.name}#{opt}"

    names = (formatArgument(argument) for argument in method.arguments)
    names.join(', ')

  renderReferences: (text) ->
    text?.replace /`?\{\S*\}`?/g, (match) =>
      return match if match.match(/^`.*`$/)
      @renderReference(match)

  renderReference: (ref) ->
    result = @resolveReference(ref)
    if typeof result is 'string'
      result
    else
      @renderTemplate('reference', result)

  renderMarkdown: (content, options={}) ->
    return '' unless content
    output = marked content,
      gfm: true
      smartypants: true
      highlight: (code, lang) ->
        if lang
          highlightjs.highlight(lang, code).value
        else
          code
    output = output.replace(/<\/?p>/g, '') if options.noParagraph
    output

  renderTemplate: (templateName, locals, options={}) ->
    unless template = @compiledTemplates[templateName]
      templatePath = path.join(path.dirname(__dirname), 'lib', 'templates', templateName + '.haml')
      templateSource = fs.readFileSync(templatePath).toString()
      template = hamlc.compile(templateSource, escapeAttributes: false)
      @compiledTemplates[templateName] = template

    if options.resolve
      for field in options.resolve
        locals[field] = @renderReferences(locals[field])

    if options.markdown
      for field in options.markdown
        locals[field] = @renderMarkdown(locals[field], noParagraph: options.noParagraph)

    content = template locals
    content.replace(/\n\n/, '\n')

  ###
  Section: Resolve Referneces
  ###

  mozillaJavascriptBaseUrl = 'https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects'
  mozillaWebBaseUrl = 'https://developer.mozilla.org/en-US/docs/Web/API'
  atomBaseUrl = 'https://atom.io/docs/api/latest'

  initReferenceMap: ->
    @referenceMap = {}

    mozillaJavascript = [
      'Object'
      'String'
      'Array'
      'Function'
      'Boolean'
      'Symbol'
      'Error'
      'Number'
      'Date'
      'RegExp'
      'Infinity'
      'NaN'
    ]

    for item in mozillaJavascript
      @addReference(item, "#{mozillaJavascriptBaseUrl}/#{item}")

    mozillaWeb = [
      'HTMLDocument'
    ]

    for item in mozillaWeb
      @addReference(item, "#{mozillaWebBaseUrl}/#{item}")

    atom = [
      'Color'
      'CommandRegistry'
      'CompositeDisposable'
      'Config'
      'Decoration'
      'Disposable'
      'Emitter'
      'Marker'
      'Notification'
      'NotificationManager'
      'Point'
      'Range'
      'TextEditor'
      'TooltipManager'
      'ViewRegistry'
      'Workspace'
      'BufferedNodeProcess'
      'BufferedProcess'
      'Clipboard'
      'ContextMenuManager'
      'Cursor'
      'DeserializerManager'
      'Directory'
      'File'
      'GitRepository'
      'Grammar'
      'GrammarRegistry'
      'KeymapManager'
      'MenuManager'
      'PackageManager'
      'Pane'
      'Panel'
      'Project'
      'ScropeDescriptor'
      'Selection'
      'StyleManager'
      'Task'
      'TextBuffer'
      'ThemeManager'
    ]

    for item in atom
      @addReference(item, "#{atomBaseUrl}/#{item}")

  addReference: (name, url) ->
    @referenceMap[name] = url

  resolveReference: (text) ->
    itemText = text.replace(/\{(.*)\}/, '$1')

    if itemText.indexOf('.') isnt -1
      type = 'static'
      [klass, item] = itemText.split('.')
    else if itemText.indexOf('::') isnt -1
      type = 'instance'
      [klass, item] = itemText.split('::')

    switch type
      when 'static' then @resolveStaticReference(klass, item, itemText)
      when 'instance' then @resolveInstanceReference(klass, item, itemText)
      else @resolveClassReference(itemText, text)

  resolveStaticReference: (klass, item, text) ->
    switch
      when klass is '' then { name: text, url: "#static-#{item}" }
      when @metadata.classes[klass] then { name: text, url: "#{klass}.html#static-#{item}" }
      when @referenceMap[klass] then { name: text, url: "#{mozillaJavascriptBaseUrl}/#{klass}/#{item}" }

  resolveInstanceReference: (klass, item, text) ->
    switch
      when klass is '' then { name: text, url: "#instance-#{item}" }
      when @metadata.classes[klass] then { name: text, url: "#{klass}.html#instance-#{item}" }
      when @referenceMap[klass] then { name: text, url: "#{mozillaJavascriptBaseUrl}/#{klass}/#{item}" }

  resolveClassReference: (klass, text) ->
    switch
      when @metadata?.classes?[klass]
        { name: klass, url: klass + '.html'}
      when @referenceMap[klass]
        { name: klass, url: @referenceMap[klass] }
      else text

module.exports = new Renderer
