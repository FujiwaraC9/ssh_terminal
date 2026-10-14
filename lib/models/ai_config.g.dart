part of 'ai_config.dart';

class AiConfigAdapter extends TypeAdapter<AiConfig> {
  @override
  final int typeId = 1;

  @override
  AiConfig read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return AiConfig(
      apiKey: fields[0] as String,
      baseUrl: fields[1] as String,
      model: fields[2] as String,
      temperature: fields[3] as double,
    );
  }

  @override
  void write(BinaryWriter writer, AiConfig obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.apiKey)
      ..writeByte(1)
      ..write(obj.baseUrl)
      ..writeByte(2)
      ..write(obj.model)
      ..writeByte(3)
      ..write(obj.temperature);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiConfigAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
