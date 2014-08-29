part of streamy.generator;

class StreamyClient {
  final Config config;
  final DartFile root;
  final DartFile resources;
  final DartFile requests;
  final DartFile objects;
  final DartFile dispatch;
  
  StreamyClient(this.config, this.root, this.resources, this.requests, this.objects, this.dispatch);
}

class SchemaDefinition {
  final DartClass clazz;
  final DartTypedef globalDef;
  
  SchemaDefinition(this.clazz, this.globalDef);
}

class Emitter {
  final Config config;
  final Map<String, mustache.Template> templates;
  
  Emitter(this.config, this.templates);

  static final BASE_PREFIX = '_streamy_base_';

  static final List<String> TEMPLATES = const [
    'lazy_resource_getter',
    'map',
    'marshal',
    'marshal_handle',
    'marshal_mapbacked',
    'object_add_global',
    'object_clone',
    'object_ctor',
    'object_getter',
    'object_patch',
    'object_remove',
    'object_setter',
    'request_clone',
    'request_ctor',
    'request_marshal_payload',
    'request_method',
    'request_param_getter',
    'request_param_setter',
    'request_remove',
    'request_send',
    'request_send_direct',
    'request_unmarshal_response',
    'root_begin_transaction',
    'root_constructor',
    'root_send',
    'root_transaction_constructor',
    'string_list',
    'string_map',
    'unmarshal'
  ];
      
  static Future<Emitter> fromTemplateLoader(Config config, TemplateLoader loader) {
    var templates = <String, mustache.Template>{};
    var futures = <Future>[];
    TEMPLATES.forEach((name) => futures.add(loader
      .load(name)
      .then((template) {
        templates[name] = template;
      })));
    return Future
      .wait(futures)
      .then((_) => new Emitter(config, templates));
  }
  
  StreamyClient process(Api api) {
    var client;
    var rootFile, rootPrefix;
    var resourceFile, resourcePrefix;
    var requestFile, requestPrefix;
    var objectFile, objectPrefix;
    var dispatchFile, dispatchPrefix;
    var libPrefix = api.name;
    if (api.httpConfig != null) {
      libPrefix = "$libPrefix";
    }
    rootFile = new DartLibrary(libPrefix)
      ..imports['package:streamy/streamy.dart'] = 'streamy'
      ..imports['package:fixnum/fixnum.dart'] = 'fixnum'
      ..imports[config.baseImport] = BASE_PREFIX
      ..imports['dart:async'] = null;
    var out = [rootFile];
    switch (config.splitLevel) {
      case SPLIT_LEVEL_NONE:
        resourceFile = rootFile;
        requestFile = rootFile;
        objectFile = rootFile;
        dispatchFile = rootFile;
        client = new StreamyClient(config, rootFile, null, null, null, null);
        break;
      case SPLIT_LEVEL_PARTS:
        resourceFile = new DartLibraryPart(rootFile.libraryName,
            '${config.outputPrefix}_resources.dart');
        requestFile = new DartLibraryPart(rootFile.libraryName,
            '${config.outputPrefix}_requests.dart');
        objectFile = new DartLibraryPart(rootFile.libraryName,
            '${config.outputPrefix}_objects.dart');
        dispatchFile = new DartLibraryPart(rootFile.libraryName,
            '${config.outputPrefix}_dispatch.dart');
        rootFile.parts.addAll([resourceFile, requestFile, objectFile, dispatchFile]);
        out.addAll([resourceFile, requestFile, objectFile, dispatchFile]);
        client = new StreamyClient(config, rootFile, resourceFile, requestFile, objectFile, dispatchFile);
        break;
      case SPLIT_LEVEL_LIBS:
        resourceFile = new DartLibrary('$libPrefix.resources');
        requestFile = new DartLibrary('$libPrefix.requests');
        objectFile = new DartLibrary('$libPrefix.objects');
        dispatchFile = new DartLibrary('$libPrefix.dispatch');
        resourcePrefix = 'resources';
        requestPrefix = 'requests';
        objectPrefix = 'objects';
        dispatchPrefix = 'dispatch';
        rootFile.imports
          ..[importPath('resources.dart')] = 'resources'
          ..[importPath('dispatch.dart')] = 'dispatch';
        resourceFile.imports
          ..['package:streamy/streamy.dart'] = 'streamy'
          ..['package:fixnum/fixnum.dart'] = 'fixnum'
          ..[config.baseImport] = BASE_PREFIX
          ..[importPath('requests.dart')] = 'requests'
          ..[importPath('objects.dart')] = 'objects';
        requestFile.imports
          ..['package:streamy/streamy.dart'] = 'streamy'
          ..['package:fixnum/fixnum.dart'] = 'fixnum'
          ..[config.baseImport] = BASE_PREFIX
          ..[importPath('objects.dart')] = 'objects'
          ..[importPath('dispatch.dart')] = 'dispatch'
          ..['dart:async'] = null;
        objectFile.imports
          ..['package:streamy/streamy.dart'] = 'streamy'
          ..['package:fixnum/fixnum.dart'] = 'fixnum'
          ..[config.baseImport] = BASE_PREFIX;
        dispatchFile.imports
          ..['package:streamy/streamy.dart'] = 'streamy'
          ..['package:fixnum/fixnum.dart'] = 'fixnum'
          ..[config.baseImport] = BASE_PREFIX
          ..[importPath('objects.dart')] = 'objects';
        out.addAll([resourceFile, requestFile, objectFile, dispatchFile]);
        resourceFile.imports.addAll(api.imports);
        requestFile.imports.addAll(api.imports);
        objectFile.imports.addAll(api.imports);
        dispatchFile.imports.addAll(api.imports);
        client = new StreamyClient(config, rootFile, resourceFile, requestFile, objectFile, dispatchFile);
        break;
    }
    
    rootFile.imports.addAll(api.imports);
    
    // Root class
    if (config.generateApi) {
      rootFile.classes.addAll(processRoot(api, resourcePrefix, dispatchPrefix));
      resourceFile.classes.addAll(processResources(api, requestPrefix, objectPrefix));
      requestFile.classes.addAll(processRequests(api, objectPrefix, dispatchPrefix));
    }
    var schemas = processSchemas(api);
    objectFile.classes.addAll(schemas.map((schema) => schema.clazz));
    objectFile.typedefs.addAll(schemas.map((schema) => schema.globalDef).where((v) => v != null));
    if (config.generateMarshallers) {
      dispatchFile.classes.add(processMarshaller(api, objectPrefix));
    }
    return client;
  }
  
  List<DartClass> processRoot(Api api, String resourcePrefix, String dispatchPrefix) {
    // Create the resource mixin class.
    var resourceMixin = new DartClass('${_makeClassName(api.name)}ResourcesMixin');
    if (api.description != null) {
      resourceMixin.comments.addAll(splitStringAcrossLines(api.description));
    }
    
    // Implement backing fields and lazy getters for each resource type.
    api.resources.forEach((name, resource) =>
        _addLazyGetter(resourceMixin, name, resource, resourcePrefix));
    
    var baseType = streamyImport('Root');
    if (api.httpConfig != null) {
      baseType = streamyImport('HttpRoot');
    }
    final marshallerType = new DartType('Marshaller', dispatchPrefix, const []);
    var mixinType = new DartType.from(resourceMixin);
    var txClassName = _makeClassName('${api.name}Transaction');
    var root = new DartClass(_makeClassName(api.name), baseClass: baseType)
      ..mixins.add(mixinType)
      ..fields.add(new DartSimpleField('marshaller', marshallerType, isFinal: true))
      ..fields.add(new DartSimpleField('requestHandler', streamyImport('RequestHandler'), isFinal: true))
      ..fields.add(new DartSimpleField('txStrategy', streamyImport('TransactionStrategy'), isFinal: true))
      ..fields.add(new DartSimpleField('tracer', streamyImport('Tracer'), isFinal: true))
      ..methods.add(new DartMethod(
        'beginTransaction',
        new DartType(txClassName, null, const []),
        new DartTemplateBody(_template('root_begin_transaction'), {'txClassName': txClassName})));

    var ctorData = {
      'http': api.httpConfig != null
    };
    var ctor = new DartConstructor(root.name, body: new DartTemplateBody(
      _template('root_constructor'), ctorData))
      ..parameters.add(new DartParameter('requestHandler',
          streamyImport('RequestHandler'), isDirectAssignment: true))
      ..namedParameters.add(new DartNamedParameter('txStrategy',
          streamyImport('TransactionStrategy'),
          isDirectAssignment: true))
      ..namedParameters.add(new DartNamedParameter('tracer', streamyImport('Tracer'),
          isDirectAssignment: true,
          defaultValue: new DartConstantBody('const streamy.NoopTracer()')))
      ..namedParameters.add(new DartNamedParameter('marshaller', marshallerType,
          isDirectAssignment: true,
          defaultValue: new DartConstantBody('const ${marshallerType}()')));
    if (api.httpConfig != null) {
      ctor.namedParameters.add(new DartNamedParameter('servicePath',
          const DartType.string(),
          defaultValue: new DartConstantBody("r'${api.httpConfig.servicePath}'")));
    }
    root.methods.add(ctor);
    
    var send = new DartMethod('send', new DartType('Stream', null, const []),
      new DartTemplateBody(_template('root_send'), {})
    )
      ..parameters.add(new DartParameter('request', streamyImport('Request')));
    root.methods.add(send);
    
    addApiType(root);

    var txRoot = new DartClass(
        txClassName,
        baseClass: streamyImport('HttpTransactionRoot'))
      ..fields.add(new DartSimpleField('marshaller', marshallerType, isFinal: true))
      ..mixins.add(mixinType);

    var txnCtor = new DartConstructor(txRoot.name, body: new DartTemplateBody(
      _template('root_transaction_constructor'), {}));
    txnCtor.parameters
      ..add(new DartParameter('txn', streamyImport('Transaction')))
      ..add(new DartParameter('servicePath', const DartType.string()))
      ..add(new DartParameter('marshaller', marshallerType,
          isDirectAssignment: true));
    txRoot.methods.add(txnCtor);

    addApiType(txRoot);

    return [resourceMixin, root, txRoot];
  }

  List<DartClass> processResources(Api api, String requestPrefix, String objectPrefix) =>
    api
      .resources
      .values
      .expand(_expandResources)
      .map((resource) => processResource(resource, requestPrefix, objectPrefix))
      .toList(growable: false);
  
  DartClass processResource(Resource resource, String requestPrefix,
      String objectPrefix) {
    var clazz = new DartClass('${_makeClassName(resource.name)}Resource');
    var requestMethodTemplate = _template('request_method');
    
    // Set up a _root field for the implementation RequestHandler, and a
    // constructor that sets it.
    var rootType = streamyImport('Root');
    clazz.fields.add(new DartSimpleField('_root', rootType, isFinal: true));
    var ctor = new DartConstructor(clazz.name);
    ctor.parameters.add(new DartParameter('_root', rootType, isDirectAssignment: true));
    clazz.methods.add(ctor);
    
    
    if (config.known) {
      clazz.fields.add(new DartSimpleField('KNOWN_METHODS',
          new DartType.list(const DartType.string()),
          isFinal: true, isStatic: true,
          initializer: stringListBody(resource.methods.values.map((m) => m.name))));
    }
    
    resource.methods.forEach((_, method) {
      var plist = [];
      var pnames = [];
      var payloadType;
      
      // Resource methods get a Request object. Either they're built using
      // request URL parameters, or the payload object.
      if (method.payloadType != null) {
        payloadType = toDartType(method.payloadType, objectPrefix);
        plist.add(new DartParameter('payload', payloadType));
      } else {
        method.httpPath.parameters().forEach((param) {
          if (!method.parameters.containsKey(param)) {
            return;
          }
          var pRecord = method.parameters[param];
          var pType = toDartType(pRecord.typeRef, objectPrefix);
          plist.add(new DartParameter(param, pType));
          pnames.add(param);
        });
      }
      
      var requestType = new DartType(
          _makeClassName(_joinParts([resource.name, method.name, 'Request'])),
          requestPrefix, const []);
      
      var m = new DartMethod(_makeMethodName(method.name), requestType,
          new DartTemplateBody(requestMethodTemplate, {
            'requestType': requestType,
            'parameters': pnames
              .map((name) => {'name': name})
              .toList(growable: false),
            'hasPayload': payloadType != null
          }));
      m.parameters.addAll(plist);
      clazz.methods.add(m);
    });
    
    resource.subresources.forEach((name, resource) =>
        _addLazyGetter(clazz, name, resource, null));
    
    addApiType(clazz);
    return clazz;
  }
  
  String importPath(String file) {
    return config.importPrefix + config.outputPrefix + '_' + file;
  }
  
  List<DartClass> processRequests(Api api, String objectPrefix, String dispatchPrefix) =>
    api
      .resources
      .values
      .expand(_expandResources)
      .expand((resource) => resource
        .methods
        .values
        .map((method) => processRequest(api, _makeClassName(resource.name),
            method, objectPrefix, dispatchPrefix))
      )
      .toList(growable: false);

  DartClass processRequest(Api api, String resourceClassName, Method method,
      String objectPrefix, String dispatchPrefix) {
    var paramGetter = _template('request_param_getter');
    var paramSetter = _template('request_param_setter');
    var requestClassName = _makeClassName(
        _joinParts([resourceClassName, method.name, 'Request']));
    var clazz = new DartClass(
        requestClassName,
        baseClass: streamyImport('HttpRequest'));

    // Determine payload type.
    var payloadType;
    if (method.payloadType != null) {
        payloadType = toDartType(method.payloadType, objectPrefix);
    }
    
    var listParams = method
      .parameters
      .values
      .where((param) => param.typeRef is ListTypeRef)
      .map((param) => {'name': param.name, 'type': toDartType(param.typeRef.subType, objectPrefix)})
      .toList(growable: false);
    
    // Set up a _root field for the implementation RequestHandler, and a
    // constructor that sets it.
    var rootType = streamyImport('Root');
    var ctor = new DartConstructor(clazz.name, body: new DartTemplateBody(
      _template('request_ctor'), {
        'hasPayload': payloadType != null,
        'hasListParams': listParams.isNotEmpty,
        'listParams': listParams
    }))
      ..parameters.add(new DartParameter('root', rootType));
    if (payloadType != null) {
        ctor.parameters.add(new DartParameter('payload', payloadType));
    }
    clazz.methods.add(ctor);
    
    if (config.known) {
      clazz.fields.add(new DartSimpleField('KNOWN_PARAMETERS',
          new DartType.list(const DartType.string()),
          isStatic: true, isFinal: true,
          initializer: stringListBody(
              method.parameters.values.map((p) => p.name))));
    }
    
    // Set up fields for all the preferences.
    method.parameters.forEach((name, param) {
      var type = toDartType(param.typeRef, objectPrefix);
      clazz.fields.add(
          new DartComplexField(_makePropertyName(name), type,
              new DartTemplateBody(paramGetter, {'name': name}),
              new DartTemplateBody(paramSetter, {'name': name})));
      clazz.methods.add(new DartMethod(_makeRemoverName(name), type,
          new DartTemplateBody(_template('request_remove'), {'name': name})));
    });
    
    addApiType(clazz);
    
    clazz.fields
      ..add(new DartComplexField.getterOnly('hasPayload',
          const DartType.boolean(), new DartConstantBody(
              '=> ${method.payloadType != null};')))
      ..add(new DartComplexField.getterOnly('httpMethod',
          const DartType.string(), new DartConstantBody(
              "=> r'${method.httpMethod}';")))
      ..add(new DartComplexField.getterOnly('pathFormat',
          const DartType.string(), new DartConstantBody(
              "=> r'${method.httpPath}';")))
      ..add(new DartComplexField.getterOnly('pathParameters',
          new DartType.list(const DartType.string()), stringListBody(
              method
                .parameters
                .values
                .where((p) => p.location == 'path')
                .map((p) => p.name), getter: true)))
      ..add(new DartComplexField.getterOnly('queryParameters',
          new DartType.list(const DartType.string()), stringListBody(
              method
                .parameters
                .values
                .where((p) => p.location != 'path')
                .map((p) => p.name), getter: true)));

    // Set up send() methods.
    var sendParams = config.sendParams.map((p) {
      var type = toDartType(p.typeRef, objectPrefix);
      var defaultValue;
      if (p.defaultValue != null) {
        if (p.defaultValue is String) {
          defaultValue = new DartConstantBody("r'${p.defaultValue}'");
        } else {
          defaultValue = new DartConstantBody(p.defaultValue.toString());
        }
      }
      return new DartNamedParameter(p.name, type, defaultValue: defaultValue);
    }).toList();
    
    var sendDirectTemplate = _template('request_send_direct');
    var sendTemplate = _template('request_send');
    
    // Add _sendDirect.
    var responseType;
    var responseParams = [];
    if (method.responseType != null) {
      responseType = toDartType(method.responseType, objectPrefix);
      responseParams.add(responseType);
    }
    var rawType = new DartType.stream(
        streamyImport('Response', params: responseParams));
    clazz.methods.add(new DartMethod('_sendDirect', rawType,
        new DartTemplateBody(sendDirectTemplate, {})));
    
    // Add send().
    var sendType;
    if (responseType == null) {
      sendType = new DartType('Stream', null, const []);
    } else {
      sendType = new DartType.stream(responseType);
    }

    if (config.generateMarshallers) {
      if (responseType != null && api.httpConfig != null) {
        clazz.methods.add(new DartMethod('unmarshalResponse', responseType,
        new DartTemplateBody(_template('request_unmarshal_response'), {
            'name': _makeClassName((method.responseType as SchemaTypeRef).schemaClass)
        }))
          ..parameters.add(new DartParameter('data', new DartType('Map', null, const []))));
      }

      if (method.payloadType != null) {
        clazz.methods.add(new DartMethod('marshalPayload', new DartType('Map'),
        new DartTemplateBody(_template('request_marshal_payload'), {
            'name': _makeClassName((method.payloadType as SchemaTypeRef).schemaClass)
        })));
      }
    }

    var sendParamNames = sendParams
      .map((p) => {'name': p.name})
      .toList(growable: false);
    
    var send = new DartMethod('send', sendType, new DartTemplateBody(
        sendTemplate, {
          'sendParams': sendParamNames,
          'listen': false,
          'raw': false,
        }))
      ..namedParameters.addAll(sendParams);
    clazz.methods.add(send);
    
    // Add sendRaw().
    var sendRaw = new DartMethod('sendRaw', rawType, new DartTemplateBody(
        sendTemplate, {
          'sendParams': sendParamNames,
          'listen': false,
          'raw': true
        }
    ))
      ..namedParameters.addAll(sendParams);
    clazz.methods.add(sendRaw);
    
    var listenType = new DartType('StreamSubscription', null, responseParams);
    var listen = new DartMethod('listen', listenType, new DartTemplateBody(
      sendTemplate, {
        'sendParams': sendParamNames,
        'listen': true,
        'raw': false
      }
    ))
      ..parameters.add(new DartParameter('onData', const DartType('Function')))
      ..namedParameters.addAll(sendParams);
    clazz.methods.add(listen);
    
    var clone = new DartMethod('clone',
        new DartType(clazz.name, null, const []),
        new DartTemplateBody(_template('request_clone'), {
          'type': clazz.name,
          'hasPayload': payloadType != null
    }));
    clazz.methods.add(clone);
    
    return clazz;
  }
  
  List<SchemaDefinition> processSchemas(Api api) => api
    .types
    .values
    .map(processSchema)
    .toList(growable: false);

  DartClass processMarshaller(Api api, String objectPrefix) {
    var marshallerClass = new DartClass('Marshaller');
    marshallerClass.methods.add(new DartConstructor(marshallerClass.name, isConst: true));
    api.types.values.forEach((schema) =>
        processSchemaForMarshaller(marshallerClass, schema, objectPrefix));
    return marshallerClass;
  }

  SchemaDefinition processSchema(Schema schema) {
    var base = new DartType(config.baseClass, BASE_PREFIX, const []);
    var clazz = new DartClass(_makeClassName(schema.name), baseClass: base);
    clazz.mixins.addAll(schema.mixins.map((mixin) => toDartType(mixin, '')));

    var globalFnDef = null;

    var ctor = _template('object_ctor');
    var getter = _template('object_getter');
    var setter = _template('object_setter');
    var remove = _template('object_remove');

    clazz.methods.add(new DartConstructor(clazz.name, body: new DartTemplateBody(
      ctor, {
        'mapBacked': config.mapBackedFields,
        'wrap': false,
        'basePrefix': BASE_PREFIX,
      })));
      
    if (config.mapBackedFields) {
      clazz.methods.add(new DartConstructor(clazz.name, named: 'wrap',
        body: new DartTemplateBody(ctor, {
          'mapBacked': true,
          'wrap': true,
          'basePrefix': BASE_PREFIX,
        }))
        ..parameters.add(new DartParameter('map', new DartType.map(const DartType.string(), const DartType.dynamic()))));
    }

    if (config.known) {
      clazz.fields.add(new DartSimpleField('KNOWN_PROPERTIES',
          new DartType.list(const DartType.string()),
          isFinal: true, isStatic: true,
          initializer: stringListBody(schema.properties.values.map((m) => m.name))));
    }

    if (config.global) {
      globalFnDef = new DartTypedef('${clazz.name}GlobalFn', const DartType.dynamic())
        ..parameters.add(new DartParameter('entity', new DartType.from(clazz)));
      clazz.methods.add(new DartMethod('addGlobal', const DartType.none(), new DartTemplateBody(
        _template('object_add_global'), {'type': clazz.name}), isStatic: true)
        ..parameters.add(new DartParameter('name', const DartType.string()))
        ..parameters.add(new DartParameter('computeFn', new DartType.from(globalFnDef)))
        ..namedParameters.add(new DartNamedParameter('memoize', const DartType.boolean(), defaultValue: new DartConstantBody('false')))
        ..namedParameters.add(new DartNamedParameter('dependencies', new DartType('List', null, const []))));
    }

    schema.properties.forEach((_, field) {
      // Add getter and setter, delegating to map access.
      var name = _makePropertyName(field.name);
      var type = toDartType(field.typeRef, null);
      if (config.mapBackedFields) {
        var f = new DartComplexField(name, type,
            new DartTemplateBody(getter, {'name': field.name}),
            new DartTemplateBody(setter, {'name': field.name}));
        clazz.fields.add(f);
        if (config.removers) {
          var r = new DartMethod(_makeRemoverName(field.name), type,
              new DartTemplateBody(remove, {'name': field.name}));
        clazz.methods.add(r);
        }
      } else {
        var f = new DartSimpleField(name, type);
        clazz.fields.add(f);
      }
    });

    var schemaType = new DartType.from(clazz);
    if (config.clone) {
      clazz.methods.add(new DartMethod('clone', schemaType,
          new DartTemplateBody(_template('object_clone'), {'type': schemaType})));
    }
    if (config.patch) {
      clazz.methods.add(new DartMethod('patch', schemaType,
          new DartTemplateBody(_template('object_patch'), {'type': schemaType})));
    }
    if (config.global) {
      clazz.methods.add(new DartComplexField.getterOnly('streamyType',
         new DartType('Type'), new DartConstantBody('=> ${clazz.name};')));
    }

    addApiType(clazz);

    return new SchemaDefinition(clazz, globalFnDef);
  }

  _accumulateMarshallingTypes(String name, TypeRef typeRef, List<String> int64Fields, List<String> doubleFields, Map entityFields) {
    switch (typeRef.base) {
      case 'int64':
        int64Fields.add(name);
        break;
      case 'double':
        doubleFields.add(name);
        break;
      case 'schema':
        entityFields[name] = (typeRef as SchemaTypeRef).schemaClass;
        break;
      case 'list':
        _accumulateMarshallingTypes(name, (typeRef as ListTypeRef).subType,
            int64Fields, doubleFields, entityFields);
        break;
    }
  }

  void processSchemaForMarshaller(DartClass clazz, Schema schema, String objectPrefix) {
    var name = _makeClassName(schema.name);
    var type = new DartType(name, objectPrefix, const []);
    var rt = new DartType.map(const DartType.string(), const DartType.dynamic());
    var data = {
      'fields': []
    };
    var marshal = _template('marshal');
    var unmarshal = _template('unmarshal');

    var allFields = [];
    var int64Fields = [];
    var doubleFields = [];
    var entityFields = {};

    schema
      .properties
      .forEach((_, field) {
        _accumulateMarshallingTypes(field.name, field.typeRef, int64Fields,
            doubleFields, entityFields);
        allFields.add({
          'key': field.name,
          'identifier': _makePropertyName(field.name),
        });
      });

    var stringList = new DartType.list(const DartType.string());
    var serialMap = new DartType('Map');
    if (int64Fields.isNotEmpty) {
      clazz.fields.add(new DartSimpleField('_int64s$name', stringList,
          isStatic: true, isFinal: true,
              initializer: stringListBody(int64Fields)));
    }
    if (doubleFields.isNotEmpty) {
      clazz.fields.add(new DartSimpleField('_doubles$name', stringList,
          isStatic: true, isFinal: true,
              initializer: stringListBody(doubleFields)));
    }
    
    var fieldMapping = {};
    schema.properties.values.forEach((field) {
      if (field.key != null) {
        fieldMapping[field.key] = field.name;
      }
    });
    if (fieldMapping.isNotEmpty) {
      clazz.fields.add(new DartSimpleField('_fieldMapping$name', serialMap,
          isStatic: true, isFinal: true,
          initializer: mapBody(fieldMapping)));
      clazz.fields.add(new DartSimpleField('_fieldUnmapping$name', serialMap,
          isStatic: true, isFinal: true,
          initializer: mapBody(invertMap(fieldMapping))));
    }
    if (entityFields.isNotEmpty) {
      var data = [];
      entityFields.forEach((name, schema) {
        data.add({
          'key': name,
          'value': _makeHandlerName(schema),
        });
      });
      clazz.fields.add(new DartComplexField.getterOnly('_entities$name', rt,
          new DartTemplateBody(_template('map'), {
            'pairs': data,
            'getter': true,
            'const': false,
          })));
    }
    var serializerConfig = {
      'entity': type,
      'name': name,
      'fromFields': !config.mapBackedFields,
      'fields': allFields,
      'hasInt64s': int64Fields.isNotEmpty,
      'int64s': int64Fields,
      'hasDoubles': doubleFields.isNotEmpty,
      'doubles': doubleFields,
      'hasEntities': entityFields.isNotEmpty,
      'hasFieldMapping': fieldMapping.isNotEmpty,
      'basePrefix': BASE_PREFIX,
    };
    clazz.methods.add(new DartMethod('marshal$name', rt,
        new DartTemplateBody(marshal, serializerConfig))
      ..parameters.add(new DartParameter('entity', type)));
    clazz.methods.add(new DartMethod('unmarshal$name', type,
        new DartTemplateBody(unmarshal, serializerConfig))
      ..parameters.add(new DartParameter('data', rt)));
    clazz.methods.add(new DartMethod('_handle$name', const DartType.dynamic(), new DartTemplateBody(_template('marshal_handle'), {
        'type': name
      }), isStatic: true)
        ..parameters.add(new DartParameter('marshaller', new DartType('Marshaller', null, const [])))
        ..parameters.add(new DartParameter('data', const DartType.dynamic()))
        ..parameters.add(new DartParameter('marshal', const DartType.boolean())));
  }

  void addApiType(DartClass clazz) {
    clazz.fields.add(new DartSimpleField('API_TYPE', const DartType.string(),
        initializer: new DartConstantBody("r'${clazz.name}'"),
        isStatic: true, isFinal: true));
    clazz.fields.add(new DartComplexField.getterOnly('apiType',
        const DartType.string(), new DartConstantBody("=> r'${clazz.name}';")));
  }

  DartBody stringListBody(Iterable<String> strings, {bool getter: false}) =>
      new DartTemplateBody(_template('string_list'), {
        'list': strings.map((i) => {'value': i}).toList(growable: false),
        'getter': getter
      });

  DartBody mapBody(Map<String, String> map) {
    var data = [];
    map.forEach((key, value) {
      data.add({'key': key, 'value': value});
    });
    return new DartTemplateBody(_template('string_map'), {'map': data});
  }
  
  Map invertMap(Map input) {
    Map output = {};
    input.forEach((key, value) {
      output[value] = key;
    });
    return output;
  }

  DartType streamyImport(String clazz, {params: const []}) =>
      new DartType(clazz, 'streamy', params);

  DartType toDartType(TypeRef ref, String objectPrefix) {
    if (ref is ListTypeRef) {
      return new DartType.list(toDartType(ref.subType, objectPrefix));
    } else if (ref is SchemaTypeRef) {
      return new DartType(_makeClassName(ref.schemaClass), objectPrefix, const []);
    } else {
      switch (ref.base) {
        case 'int64':
          return new DartType('Int64', 'fixnum', const []);
        case 'integer':
          return const DartType.integer();
        case 'string':
          return const DartType.string();
        case 'any':
          return const DartType.dynamic();
        case 'double':
          return const DartType.double();
        case 'boolean':
          return const DartType.boolean();
        case 'number':
          return const DartType.double();
        case 'external':
          ExternalTypeRef externalTypeRef = ref;
          return new DartType(externalTypeRef.type,
              externalTypeRef.importedFrom, const []);
        default:
          throw new Exception('Unhandled API type: $ref');
      }
    }
  }

  mustache.Template _template(String name) => templates[name];
  
  _addLazyGetter(DartClass clazz, String name, Resource resource, String resourcePrefix) {
    var getterTemplate = _template('lazy_resource_getter');

    // Backing field.
    var fieldName = _makePropertyName(name);
    var privateFieldName = '_$fieldName';
    var type = new DartType('${_makeClassName(resource.name)}Resource',
        resourcePrefix, const []);
    var field = new DartSimpleField(privateFieldName, type);
    clazz.fields.add(field);
    
    // Lazy getter.
    var root = clazz.fields.any((DartField field) => field.name == '_root')
        ? '_root' : 'this as streamy.Root';
    var templateBody = new DartTemplateBody(
        getterTemplate, {'field': privateFieldName, 'resource': type, 'root': root});
    var getter = new DartComplexField.getterOnly(fieldName, type, templateBody);
    clazz.fields.add(getter);
  }
  
  List<Resource> _expandResources(Resource resource) {
    var expanded = [resource];
    resource.subresources.values.forEach((r) => expanded.addAll(_expandResources(r)));
    return expanded;
  }
}