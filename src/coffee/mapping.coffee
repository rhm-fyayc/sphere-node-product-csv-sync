_ = require('underscore')._
_s = require 'underscore.string'
CONS = require '../lib/constants'

class Mapping
  constructor: (options = {}) ->
    @types = options.types
    @customerGroups = options.customerGroups
    @categories = options.categories
    @taxes = options.taxes
    @channels = options.channels
    @errors = []

  mapProduct: (raw, productType) ->
    productType or= raw.master[@header.toIndex CONS.HEADER_PRODUCT_TYPE]
    rowIndex = raw.startRow

    product = @mapBaseProduct raw.master, productType, rowIndex
    product.masterVariant = @mapVariant raw.master, 1, productType, rowIndex
    for rawVariant, index in raw.variants
      rowIndex += 1 # TODO: get variantId from CSV
      product.variants.push @mapVariant rawVariant, index + 2, productType, rowIndex

    product

  mapBaseProduct: (rawMaster, productType, rowIndex) ->
    product =
      productType:
        typeId: 'product-type'
        id: productType.id
      masterVariant: {}
      variants: []

    product.categories = @mapCategories rawMaster, rowIndex
    tax = @mapTaxCategory rawMaster, rowIndex
    product.taxCategory = tax if tax

    for attribName in CONS.BASE_LOCALIZED_HEADERS
      val = @mapLocalizedAttrib rawMaster, attribName, @header.toLanguageIndex()
      product[attribName] = val if val

    unless product.slug
      product.slug = {}
      product.slug[CONS.DEFAULT_LANGUAGE] = @ensureValidSlug(_s.slugify product.name[CONS.DEFAULT_LANGUAGE])

    product

  # TODO
  # - check min length of 2
  # - check max lenght of 64
  ensureValidSlug: (slug, appendix = '') ->
    @slugs or= []
    currentSlug = "#{slug}#{appendix}"
    unless _.contains(@slugs, currentSlug)
      @slugs.push currentSlug
      return currentSlug
    @ensureValidSlug slug, Math.floor((Math.random()*89999)+10001) # five digets

  mapCategories: (rawMaster, rowIndex) ->
    return [] unless @header.has CONS.HEADER_CATEGORIES
    categories = []
    raw = rawMaster[@header.toIndex CONS.HEADER_CATEGORIES]
    return [] if _.isString(raw) and raw.length is 0
    rawCategories = raw.split CONS.DELIM_MULTI_VALUE
    for rawCategory in rawCategories
      cat =
        typeId: 'category'
      if _.contains(@categories.duplicateNames, rawCategory)
        @errors.push "[row #{rowIndex}:#{CONS.HEADER_CATEGORIES}] The category '#{rawCategory}' is not unqiue!"
        continue
      if _.has(@categories.name2id, rawCategory)
        cat.id = @categories.name2id[rawCategory]
      else if _.has(@categories.fqName2id, rawCategory)
        cat.id = @categories.fqName2id[rawCategory]

      if cat.id
        categories.push cat
      else
        @errors.push "[row #{rowIndex}:#{CONS.HEADER_CATEGORIES}] Can not find category for '#{rawCategory}'!"

    categories

  mapTaxCategory: (rawMaster, rowIndex) ->
    return unless @header.has CONS.HEADER_TAX
    rawTax = rawMaster[@header.toIndex CONS.HEADER_TAX]
    return [] if _.isString(rawTax) and rawTax.length is 0
    if _.contains(@taxes.duplicateNames, rawTax)
      @errors.push "[row #{rowIndex}:#{CONS.HEADER_TAX}] The tax category '#{rawTax}' is not unqiue!"
      return
    unless _.has(@taxes.name2id, rawTax)
      @errors.push "[row #{rowIndex}:#{CONS.HEADER_TAX}] The tax category '#{rawTax}' is unknown!"
      return

    tax =
      typeId: 'tax-category'
      id: @taxes.name2id[rawTax]

  mapVariant: (rawVariant, variantId, productType, rowIndex) ->
    variant =
      id: variantId
      attributes: []

    variant.sku = rawVariant[@header.toIndex CONS.HEADER_SKU] if @header.has CONS.HEADER_SKU

    languageHeader2Index = @header._productTypeLanguageIndexes productType
    if productType.attributes
      for attribute in productType.attributes
        attrib = @mapAttribute rawVariant, attribute, languageHeader2Index, rowIndex
        variant.attributes.push attrib if attrib

    variant.prices = @mapPrices rawVariant[@header.toIndex CONS.HEADER_PRICES], rowIndex
    variant.images = @mapImages rawVariant, variantId, rowIndex

    variant

  mapAttribute: (rawVariant, attribute, languageHeader2Index, rowIndex) ->
    value = @mapValue rawVariant, attribute, languageHeader2Index, rowIndex
    return unless value
    attribute =
      name: attribute.name
      value: value

  mapValue: (rawVariant, attribute, languageHeader2Index, rowIndex) ->
    switch attribute.type.name
      when CONS.ATTRIBUTE_TYPE_SET then @mapSetAttribute rawVariant[@header.toIndex attribute.name], attribute, languageHeader2Index, rowIndex
      when CONS.ATTRIBUTE_TYPE_LTEXT then @mapLocalizedAttrib rawVariant, attribute.name, languageHeader2Index
      when CONS.ATTRIBUTE_TYPE_NUMBER then @mapNumber rawVariant[@header.toIndex attribute.name], attribute.name, rowIndex
      when CONS.ATTRIBUTE_TYPE_MONEY then @mapMoney rawVariant[@header.toIndex attribute.name], attribute.name
      else rawVariant[@header.toIndex attribute.name] # works for text, enum and lenum

  # We currently only support Set of (l)enum
  mapSetAttribute: (raw, attribute, rowIndex) ->
    return raw unless raw
    rawValues = raw.split CONS.DELIM_MULTI_VALUE
    values = []
    for rawValue in rawValues
      values.push rawValue
    return values

  mapPrices: (raw, rowIndex) ->
    return [] unless raw
    REGEX_PRICE = /^(([A-Za-z]{2})-|)([A-Z]{3}) (\d+)( (\w*)|)(#(\w+)|)$/
    prices = []
    rawPrices = raw.split CONS.DELIM_MULTI_VALUE
    for rawPrice in rawPrices
      matchedPrice = rawPrice.match REGEX_PRICE
      unless matchedPrice
        @errors.push "[row #{rowIndex}:#{CONS.HEADER_PRICES}] Can not parse price '#{rawPrice}'!"
        continue
      country = matchedPrice[2]
      currencyCode = matchedPrice[3]
      centAmount = matchedPrice[4]
      customerGroupName = matchedPrice[6]
      channelKey = matchedPrice[8]
      price =
        value: @mapMoney "#{currencyCode} #{centAmount}", CONS.HEADER_PRICES, rowIndex
      price.country = country if country
      if customerGroupName
        unless _.has(@customerGroups.name2id, customerGroupName)
          @errors.push "[row #{rowIndex}:#{CONS.HEADER_PRICES}] Can not find customer group '#{customerGroupName}'!"
          return []
        price.customerGroup =
          typeId: 'customer-group'
          id: @customerGroups.name2id[customerGroupName]
      if channelKey
        unless _.has(@channels.key2id, channelKey)
          @errors.push "[row #{rowIndex}:#{CONS.HEADER_PRICES}] Can not find channel with key '#{channelKey}'!"
          return []
        price.channel =
          typeId: 'channel'
          id: @channels.key2id[channelKey]

      prices.push price
    prices

  # EUR 300
  # USD 999
  mapMoney: (rawMoney, attribName, rowIndex) ->
    return unless rawMoney
    REGEX_MONEY = /^([A-Z]{3}) (\d+)$/
    matchedMoney = rawMoney.match REGEX_MONEY
    unless matchedMoney
      @errors.push "[row #{rowIndex}:#{attribName}] Can not parse money '#{rawMoney}'!"
      return
    # TODO: check for correct currencyCode
    money =
      currencyCode: matchedMoney[1]
      centAmount: parseInt matchedMoney[2]

  mapNumber: (rawNumber, attribName, rowIndex) ->
    return unless rawNumber
    REGEX_NUMBER = /^\d+$/
    matchedNumber = rawNumber.match REGEX_NUMBER
    unless matchedNumber
      @errors.push "[row #{rowIndex}:#{attribName}] The number '#{rawNumber}' isn't valid!"
      return
    parseInt matchedNumber[0]

  # "a.en,a.de,a.it"
  # "hi,Hallo,ciao"
  # values:
  #   de: 'Hallo'
  #   en: 'hi'
  #   it: 'ciao'
  mapLocalizedAttrib: (row, attribName, langH2i) ->
    values = {}
    if _.has langH2i, attribName
      _.each langH2i[attribName], (index, language) ->
        values[language] = row[index]
    # fall back to non localized column if language columns could not be found
    if _.size(values) is 0
      return undefined unless @header.has attribName
      val = row[@header.toIndex attribName]
      values[CONS.DEFAULT_LANGUAGE] = val
    values

  mapImages: (rawVariant, variantId, rowIndex) ->
    return [] unless @header.has CONS.HEADER_IMAGES
    raw = rawVariant[@header.toIndex CONS.HEADER_IMAGES]
    return [] if _.isString(raw) and raw.length is 0
    rawImages = raw.split CONS.DELIM_MULTI_VALUE
    images = []
    for rawImage in rawImages
      image =
        url: rawImage
        # TODO: get dimensions from CSV - format idea: 200x400;90x90
        dimensions:
          w: 0
          h: 0
        #  label: 'TODO'
      images.push image

    images


module.exports = Mapping
