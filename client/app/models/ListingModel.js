import Immutable from 'immutable';

export const Distance = Immutable.Record({
  value: 0,
  unit: 'km',
});

export const Image = Immutable.Record({
  type: ':square',
  height: 408,
  width: 408,
  url: null,
});

export const ImageRefs = Immutable.Record({
  square: new Image(),
  square2x: new Image(),
});

export const Money = Immutable.Record({
  fractionalAmount: 0,
  code: 'USD',
});


const ListingModel = Immutable.Record({
  id: 'uuid',
  distance: new Distance(),
  price: new Money(),
  title: 'Listing',
  images: new Immutable.List([new ImageRefs({
    square: new Image(),
    square2x: new Image(),
  })]),
  authorId: 'foo',
  author: new Immutable.Record(),

  // these need to be updated
  price: 1,
  priceUnit: '$',
  per: '/ day',
  distance: 1,
  distanceUnit: 'km',
  listingURL: 'https://example.com/listing/1',
});

export const parse = (l) => new ListingModel({
  id: l.get(':id'),
  distance: l.getIn([':attributes', ':distance']),
  price: l.getIn([':attributes', ':price']),
  title: l.getIn([':attributes', ':title']),
  images: l.getIn([':attributes', ':images']),
  authorId: l.getIn([':relationships', ':author', ':id']),
});

export default ListingModel;
