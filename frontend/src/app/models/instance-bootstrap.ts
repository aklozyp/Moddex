import { Instance } from './instance';
import { ServerPropertiesDto } from './server-properties';

export interface InstanceBootstrapResponse {
  instance: Instance;
  serverProperties: ServerPropertiesDto;
}
