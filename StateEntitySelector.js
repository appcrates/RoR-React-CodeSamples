import React from 'react' 
import {observer} from 'mobx-react';
import LocationEntitySelector from './LocationEntitySelector'

const StateEntitySelector = observer(React.createClass({
  selectState: function(state, event) {
    event.preventDefault();
    this.props.store.setGeoStateFilter(state);
  },
  render: function() {
    var i = 0;
    var statesArrays = [];
    var states = this.props.store.getFilteredByMultipleLocationEntity.map((entity) =>
      entity.state
    ).filter((entity, pos, self) =>
      self.indexOf(entity) === pos // removes duplicates
    ).sort((a, b) => {
      if(a < b) return -1;
      if(a > b) return 1;
      return 0;
    })

    while(i < states.length) {
      statesArrays.push(states.slice(i, i+6));
      i = i + 6;
    }
    var toRender = statesArrays.map((array) => {
      var links = array.map((state) => {
        return(
          <div className='large-2 small-6 columns end'>
            <a
              className={state === this.props.store.geoStateFilter ? 'selected' : ''}
              onClick={this.selectState.bind(null,state)}
              key={state}>
              {state}
            </a>
          </div>
        )
      })
      return(
        <div className='row'>
          { links }
        </div>
      )
    })
    return(
      <div className='selector-container state-selector'>
        { toRender }
      </div>
    )
  }

}))

export default StateEntitySelector
