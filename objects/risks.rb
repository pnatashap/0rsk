# frozen_string_literal: true

# Copyright (c) 2019 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require_relative 'rsk'
require_relative 'risk'

# Risks.
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2019 Yegor Bugayenko
# License:: MIT
class Rsk::Risks
  def initialize(pgsql, project)
    @pgsql = pgsql
    @project = project
  end

  def add(text)
    raise Rsk::Urror, 'Risk text can\'t be empty' if text.empty?
    @pgsql.exec(
      'INSERT INTO risk (project, text) VALUES ($1, $2) RETURNING id',
      [@project, text]
    )[0]['id'].to_i
  end

  def exists?(id)
    !@pgsql.exec(
      'SELECT * FROM risk WHERE project = $1 AND id = $2',
      [@project, id]
    ).empty?
  end

  def get(id)
    require_relative 'risk'
    Rsk::Risk.new(@pgsql, id)
  end

  def fetch(query: '', limit: 10, offset: 0)
    rows = @pgsql.exec(
      [
        'SELECT risk.*, SUM(effect.impact) AS impact, risk.probability * impact AS rank FROM risk',
        'LEFT JOIN triple ON triple.risk = risk.id',
        'JOIN effect ON triple.effect = effect.id',
        'WHERE project = $1 AND text LIKE $2',
        'ORDER BY rank DESC',
        'OFFSET $3 LIMIT $4'
      ].join(' '),
      [@project, "%#{query}%", offset, limit]
    )
    rows.map do |r|
      {
        label: "R#{r['id']}: #{r['text']}",
        value: r['text'],
        fields: {
          rid: r['id'].to_i,
          probability: r['probability'].to_i,
          positive: r['positive'] == 'true'
        }
      }
    end
  end
end
