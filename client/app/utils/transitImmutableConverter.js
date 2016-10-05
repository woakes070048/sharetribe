import transit from 'transit-js';
import Immutable from 'immutable';
import { Distance, Image, ImageRefs, Money } from '../models/ListingModel';

const toDistance = ([value, unit]) => new Distance({ value, unit });

const toImage = (data) => {
  const knownStyles = {
    ':square': 'square',
    ':square_2x': 'square2x',
  };
  const images = data.map(([type, height, width, url]) =>
    new Image({ type, height, width, url }));
  const styles = images.reduce((acc, val) => {
    const style = knownStyles[val.type];
    return style ? acc.set(style, val) : acc;
  }, new ImageRefs());
  return styles;
};
const toMoney = ([fractionalAmount, currency]) => new Money({ fractionalAmount, currency });

// Outside of this file we should only pass UUID references, no need to export
const UUID = Immutable.Record({ value: '' });
const toUUID = (transitUuid) => new UUID({ value: transitUuid.toString() });

const createReader = function createReader() {
  return transit.reader('json', {
    mapBuilder: {
      init: () => Immutable.Map().asMutable(),
      add: (m, k, v) => m.set(k, v),
      finalize: (m) => m.asImmutable(),
    },
    arrayBuilder: {
      init: () => Immutable.List().asMutable(),
      add: (m, v) => m.push(v),
      finalize: (m) => m.asImmutable(),
    },
    handlers: {
      ':': (rep) => `:${rep}`,
      list: (rep) => Immutable.List(rep).asImmutable(),
      u: toUUID,
      r: (rep) => rep,
      u: (rep) => rep,
      di: toDistance,
      im: toImage,
      mn: toMoney,
    },
  });
};

const createInstance = () => {
  const reader = createReader();
  const fromJSON = (json) => reader.read(json);

  return { fromJSON };
};

export default createInstance();
